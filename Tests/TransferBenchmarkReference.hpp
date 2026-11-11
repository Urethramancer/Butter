// Optional benchmark mode of TCPPeerReference. Regression modes keep their protocol.
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/version.hpp>
#include <sys/resource.h>
#include <fcntl.h>
#include <unistd.h>
#include <filesystem>
#include <fstream>

static NSDictionary* benchmarkWindows = @{};
static NSMutableArray* benchmarkPeerErrors = [NSMutableArray array];
static void benchmarkEvent(char const* phase, std::vector<int> const& ports = {}) {
	struct rusage usage{}; require(getrusage(RUSAGE_SELF, &usage) == 0, "Cannot read CPU accounting");
	NSMutableArray* values = [NSMutableArray array]; for (int port : ports) [values addObject:@(port)];
	NSDictionary* event = @{@"phase":@(phase), @"pid":@(getpid()), @"time":@(std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count()),
		@"user":@(usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6), @"system":@(usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6),
		@"peak_rss":@(usage.ru_maxrss), @"ports":values, @"libtorrent":@(LIBTORRENT_VERSION),
		@"request_window":benchmarkWindows, @"peer_errors":benchmarkPeerErrors};
	NSData* bytes = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
	require(bytes && fwrite(bytes.bytes, 1, bytes.length, stdout) == bytes.length && fputc('\n', stdout) != EOF && fflush(stdout) == 0, "Cannot send benchmark event");
}
static NSDictionary* benchmarkCommand(char const* expected) {
	std::string line; char byte = 0;
	while (line.size() < 4096 && std::cin.get(byte)) { if (byte == '\n') break; line.push_back(byte); }
	require(byte == '\n' && line.size() < 4096, "Benchmark command missing or too large");
	NSDictionary* command = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:line.data() length:line.size()] options:0 error:nil];
	require([command[@"command"] isEqualToString:@(expected)], "Unexpected benchmark command"); return command;
}
static void benchmarkSync(std::filesystem::path const& path, bool directory = false) {
	int fd = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0));
	if (fd < 0) throw std::runtime_error("Cannot open durability barrier " + path.string() + ": " + std::strerror(errno));
	int result = ::fsync(fd); int closed = ::close(fd); require(result == 0 && closed == 0, "Durability barrier failed");
}
static void benchmarkSave(std::filesystem::path const& directory, std::vector<char> const& bytes) {
	std::filesystem::create_directories(directory);
	auto temp = directory / "resume.tmp", target = directory / "resume.dat";
	int fd = ::open(temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600); require(fd >= 0, "Cannot create resume data");
	std::size_t offset = 0;
	while (offset < bytes.size()) { auto count = ::write(fd, bytes.data() + offset, bytes.size() - offset); if (count <= 0) { ::close(fd); throw std::runtime_error("Cannot write resume data"); } offset += count; }
	int synced = ::fsync(fd); int closed = ::close(fd); require(synced == 0 && closed == 0, "Cannot flush resume data");
	std::filesystem::rename(temp, target); benchmarkSync(directory, true); benchmarkSync(directory.parent_path(), true);
}
static void benchmarkPayload(NSDictionary* item, lt::torrent_info const& info) {
	std::filesystem::path root([item[@"destination"] UTF8String]);
	std::set<std::filesystem::path> directories{root};
	for (auto index : info.files().file_range()) {
		if (info.files().pad_file_at(index)) continue;
		auto path = root / info.files().file_path(index); benchmarkSync(path);
		for (auto parent = path.parent_path(); parent != root; parent = parent.parent_path()) {
			require(parent != parent.root_path(), "Payload path escaped root"); directories.insert(parent);
		}
	}
	// Children before parents, including the parent which owns a newly created destination.
	for (auto it = directories.rbegin(); it != directories.rend(); ++it) benchmarkSync(*it, true);
	benchmarkSync(root.parent_path(), true);
}
static void benchmarkCheckAlerts(lt::session& session, std::vector<bool>* finished = nullptr, std::vector<lt::torrent_handle> const& handles = {}) {
	std::vector<lt::alert*> alerts; session.pop_alerts(&alerts);
	for (auto* alert : alerts) {
		if (auto* failure = lt::alert_cast<lt::listen_failed_alert>(alert)) throw std::runtime_error(failure->message());
		if (auto* failure = lt::alert_cast<lt::torrent_error_alert>(alert)) throw std::runtime_error(failure->message());
		if (auto* failure = lt::alert_cast<lt::file_error_alert>(alert)) throw std::runtime_error(failure->message());
		if (lt::alert_cast<lt::peer_error_alert>(alert) || lt::alert_cast<lt::peer_disconnected_alert>(alert)) {
			if (benchmarkPeerErrors.count == 64) [benchmarkPeerErrors removeObjectAtIndex:0];
			[benchmarkPeerErrors addObject:@(alert->message().c_str())];
		}
		if (finished) if (auto* done = lt::alert_cast<lt::torrent_finished_alert>(alert)) {
			for (std::size_t i = 0; i < handles.size(); ++i) if (handles[i] == done->handle) (*finished)[i] = true;
		}
	}
}
template <typename Alert> static void benchmarkBarrier(lt::session& session, std::vector<lt::torrent_handle> const& handles) {
	std::vector<bool> done(handles.size(), false);
	auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
	while (!std::all_of(done.begin(), done.end(), [](bool value) { return value; })) {
		require(std::chrono::steady_clock::now() < deadline, "Reference disk fence deadline");
		session.wait_for_alert(lt::milliseconds(20)); std::vector<lt::alert*> alerts; session.pop_alerts(&alerts);
		for (auto* alert : alerts) {
			if (lt::alert_cast<lt::file_error_alert>(alert) || lt::alert_cast<lt::torrent_error_alert>(alert)) throw std::runtime_error(alert->message());
			if (auto* barrier = lt::alert_cast<Alert>(alert)) for (std::size_t i = 0; i < handles.size(); ++i) if (handles[i] == barrier->handle) done[i] = true;
		}
	}
}
static void benchmark(NSDictionary* job, bool verify) {
	NSArray* items = job[@"items"]; bool seed = [job[@"role"] isEqualToString:@"seed"];
	require(items.count > 0 && items.count <= 4 && (seed || [job[@"role"] isEqualToString:@"download"]), "Invalid benchmark job");
	if (!verify) benchmarkEvent("prepare");
	{
	lt::settings_pack settings;
	settings.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
	for (auto option : {lt::settings_pack::enable_dht, lt::settings_pack::enable_lsd, lt::settings_pack::enable_upnp, lt::settings_pack::enable_natpmp,
		lt::settings_pack::enable_incoming_utp, lt::settings_pack::enable_outgoing_utp}) settings.set_bool(option, false);
	settings.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, true);
	settings.set_int(lt::settings_pack::in_enc_policy, lt::settings_pack::pe_disabled);
	settings.set_int(lt::settings_pack::out_enc_policy, lt::settings_pack::pe_disabled);
	settings.set_int(lt::settings_pack::alert_mask, static_cast<std::uint32_t>(lt::alert_category::error | lt::alert_category::storage | lt::alert_category::status | lt::alert_category::connect));
	lt::session session(settings);
	auto defaults = session.get_settings();
	benchmarkWindows = @{@"max_out_request_queue":@(defaults.get_int(lt::settings_pack::max_out_request_queue)),
		@"request_queue_time":@(defaults.get_int(lt::settings_pack::request_queue_time)),
		@"max_allowed_in_request_queue":@(defaults.get_int(lt::settings_pack::max_allowed_in_request_queue))};
	std::vector<lt::torrent_handle> handles;
	for (NSDictionary* item in items) {
		lt::error_code error; lt::add_torrent_params params;
		if (verify) {
			std::ifstream input(std::string([item[@"state"] UTF8String]) + "/resume.dat", std::ios::binary);
			require(input.good(), "Missing reference resume data"); std::vector<char> bytes((std::istreambuf_iterator<char>(input)), {});
			params = lt::read_resume_data(bytes, error); require(!error && params.ti, "Invalid reference resume data");
		} else params.ti = std::make_shared<lt::torrent_info>([item[@"torrent"] UTF8String], error);
		require(!error, "Invalid benchmark metadata");
		params.save_path = [item[@"destination"] UTF8String];
		params.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed); params.flags |= lt::torrent_flags::disable_pex;
		handles.push_back(session.add_torrent(params, error)); require(!error, "Cannot prepare benchmark transfer");
	}
	auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(600);
	while (true) {
		benchmarkCheckAlerts(session);
		bool ready = session.listen_port() > 0;
		for (auto const& handle : handles) {
			auto status = handle.status(); require(!status.errc, status.errc.message().c_str());
			ready &= status.state != lt::torrent_status::checking_files && status.state != lt::torrent_status::checking_resume_data;
			if (seed || verify) ready &= status.is_seeding;
		}
		if (ready) break;
		require(std::chrono::steady_clock::now() < deadline, "Reference preparation/reopen deadline"); session.wait_for_alert(lt::milliseconds(20));
	}
	if (verify) return;
	benchmarkEvent("ready", seed ? std::vector<int>(handles.size(), session.listen_port()) : std::vector<int>{});
	auto command = benchmarkCommand("start"); benchmarkEvent("start");
	if (seed) benchmarkCommand("verified");
	else {
		NSArray* ports = command[@"ports"]; require(ports.count == handles.size(), "Invalid benchmark ports");
		for (std::size_t i = 0; i < handles.size(); ++i) handles[i].connect_peer({lt::make_address("127.0.0.1"), [ports[i] unsignedShortValue]});
		std::vector<bool> finished(handles.size(), false);
		while (!std::all_of(finished.begin(), finished.end(), [](bool done) { return done; })) {
			require(std::chrono::steady_clock::now() < deadline, "Reference transfer deadline");
			session.wait_for_alert(lt::milliseconds(20)); benchmarkCheckAlerts(session, &finished, handles);
		}
	}
	benchmarkEvent("verified"); benchmarkCommand("persist"); benchmarkEvent("persistence");
	for (auto const& handle : handles) handle.pause();
	benchmarkBarrier<lt::torrent_paused_alert>(session, handles);
	for (auto const& handle : handles) handle.flush_cache();
	benchmarkBarrier<lt::cache_flushed_alert>(session, handles);
	for (std::size_t i = 0; i < handles.size(); ++i) {
		benchmarkPayload(items[i], *handles[i].torrent_file());
		handles[i].save_resume_data(lt::torrent_handle::save_info_dict);
	}
	std::vector<bool> saved(handles.size(), false);
	while (!std::all_of(saved.begin(), saved.end(), [](bool done) { return done; })) {
		require(std::chrono::steady_clock::now() < deadline, "Reference persistence deadline");
		session.wait_for_alert(lt::milliseconds(20)); std::vector<lt::alert*> alerts; session.pop_alerts(&alerts);
		for (auto* alert : alerts) {
			if (lt::alert_cast<lt::save_resume_data_failed_alert>(alert) || lt::alert_cast<lt::file_error_alert>(alert) || lt::alert_cast<lt::torrent_error_alert>(alert)) throw std::runtime_error(alert->message());
			if (auto* resume = lt::alert_cast<lt::save_resume_data_alert>(alert)) for (std::size_t i = 0; i < handles.size(); ++i) if (handles[i] == resume->handle && !saved[i]) {
				// Pause and flush alerts fence writes; explicit fsync above supplies durability.
				benchmarkSave(std::filesystem::path([items[i][@"state"] UTF8String]), lt::write_resume_data_buf(resume->params)); saved[i] = true;
			}
		}
	}
	benchmarkEvent("durable"); benchmarkCommand("stop"); benchmarkEvent("shutdown");
	} // Include session destruction in the shutdown phase and whole-process accounting.
	benchmarkEvent("stopped");
}
