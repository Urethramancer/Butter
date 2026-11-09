#import "ButterEngine.h"
#import <AppKit/AppKit.h>
#include <libtorrent/session.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/ip_filter.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/hex.hpp>
#include <map>
#include <set>
#include <atomic>
#include <fstream>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <filesystem>
namespace lt = libtorrent;
namespace fs = std::filesystem;
static NSString *str(std::string const& s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }
static std::string cpp(NSString *s) { return s.UTF8String ?: ""; }
static NSData *json(id value) { return [NSJSONSerialization dataWithJSONObject:value options:0 error:nil]; }
static std::vector<char> readFile(std::string const& path) {
	std::ifstream f(path, std::ios::binary);
	return {std::istreambuf_iterator<char>(f), {}};
}
static void writeFile(std::string const& path, std::vector<char> const& bytes) {
	NSError *error = nil;
	if (![[NSData dataWithBytes:bytes.data() length:bytes.size()] writeToFile:str(path) options:NSDataWritingAtomic error:&error])
		throw std::runtime_error(cpp(error.localizedDescription));
}
static bool safeRelative(std::string const& path) {
	fs::path relative(path);
	if (path.empty() || relative.is_absolute()) return false;
	for (auto const& part : relative) if (part == ".." || part == "." || part.empty()) return false;
	return true;
}
static NSArray *hashes(lt::info_hash_t const& h) {
	NSMutableArray *a = [NSMutableArray array];
	if (h.has_v1()) [a addObject:str(lt::aux::to_hex(h.v1))];
	if (h.has_v2()) [a addObject:str(lt::aux::to_hex(h.v2))];
	return a;
}
struct Transfer {
	lt::torrent_handle handle;
	std::vector<std::string> original;
	std::map<int, std::string> renaming;
	std::string error;
	bool moving = false;
	bool flushed = false;
	std::uint64_t order = 0;
};
@implementation ButterEngine {
	dispatch_queue_t _queue;
	std::unique_ptr<lt::session> _session;
	std::map<std::string, Transfer> _transfers;
	std::string _storage;
	NSMutableArray *_events;
	std::map<std::string, void (^)(NSData *, NSString *)> _exports;
	std::atomic<bool> _cancel;
	std::atomic<double> _creationProgress;
	int _pendingResume;
	int _boundPort;
	bool _udpBound;
	bool _pex;
	int _requestedPort;
	int _torrentPeers;
	std::string _networkError;
	std::string _saveError;
	std::uint64_t _nextOrder;
}
- (instancetype)initWithStorage:(NSString *)storage {
	if ((self = [super init])) {
		_storage = cpp(storage); _queue = dispatch_queue_create("net.grimdork.Butter.engine", DISPATCH_QUEUE_SERIAL);
		_events = [NSMutableArray array]; _pex = true; _torrentPeers = 80;
	}
	return self;
}
- (void)ensureSession {
	if (_session) return;
	fs::create_directories(_storage);
	lt::settings_pack p;
	p.set_int(lt::settings_pack::alert_mask, static_cast<std::uint32_t>(lt::alert_category::error | lt::alert_category::storage | lt::alert_category::status | lt::alert_category::port_mapping | lt::alert_category::peer | lt::alert_category::connect));
	p.set_str(lt::settings_pack::user_agent, "Butter/libtorrent-2.1.2");
	// Wait for persisted preferences before opening sockets or discovery services.
	p.set_str(lt::settings_pack::listen_interfaces, "");
	p.set_bool(lt::settings_pack::enable_dht, false); p.set_bool(lt::settings_pack::enable_lsd, false);
	p.set_bool(lt::settings_pack::enable_upnp, false); p.set_bool(lt::settings_pack::enable_natpmp, false);
	p.set_int(lt::settings_pack::connections_limit, 200);
	p.set_int(lt::settings_pack::connections_slack, 0);
	_session = std::make_unique<lt::session>(p);
}
- (std::string)identifier:(lt::torrent_handle const&)handle {
	for (auto const& [key, t] : _transfers) if (t.handle == handle) return key;
	return {};
}
- (void)save:(Transfer&)t { t.handle.save_resume_data(lt::torrent_handle::save_info_dict | lt::torrent_handle::flush_disk_cache); ++_pendingResume; }
- (void)persistPaths:(std::string const&)key transfer:(Transfer&)t {
	auto ti = t.handle.torrent_file(); if (!ti) return;
	if (t.original.empty()) for (auto i : ti->layout().file_range()) t.original.push_back(ti->layout().file_path(i));
	auto renames = t.handle.get_renamed_files(); lt::filenames current(ti->layout(), renames);
	NSMutableArray *paths = [NSMutableArray array], *pending = [NSMutableArray array];
	for (auto i : ti->layout().file_range()) [paths addObject:@{@"index":@(int(i)), @"original":str(t.original.at(int(i))), @"path":str(current.file_path(i))}];
	for (auto const& [index, target] : t.renaming) [pending addObject:@{@"index":@(index), @"path":str(target)}];
	NSData *data = json(@{@"paths":paths, @"pending":pending, @"destination":str(t.handle.status().save_path), @"reviewRequired":@(!t.error.empty())});
	writeFile(_storage + "/" + key + ".paths.json", std::vector<char>((char const *)data.bytes, (char const *)data.bytes + data.length));
}
- (void)drain {
	std::vector<lt::alert *> alerts; _session->pop_alerts(&alerts);
	for (auto *a : alerts) { try {
		
		if (auto *r = lt::alert_cast<lt::save_resume_data_alert>(a)) {
			_pendingResume = std::max(0, _pendingResume - 1);
			auto key = [self identifier:r->handle]; if (key.empty()) continue;
			writeFile(_storage + "/" + key + ".resume", lt::write_resume_data_buf(r->params));
			if (!fs::exists(_storage + "/" + key + ".torrent") && r->params.ti)
				writeFile(_storage + "/" + key + ".torrent", lt::write_torrent_file_buf(r->params, lt::write_flags::allow_missing_piece_layer));
			auto ex = _exports.find(key);
			if (ex != _exports.end()) { auto bytes = lt::write_torrent_file_buf(r->params, {}); ex->second([NSData dataWithBytes:bytes.data() length:bytes.size()], nil); _exports.erase(ex); }
		} else if (auto *r = lt::alert_cast<lt::save_resume_data_failed_alert>(a)) {
			_pendingResume = std::max(0, _pendingResume - 1);
			auto key = [self identifier:r->handle];
			auto ex = _exports.find(key); if (ex != _exports.end()) { ex->second(nil, @"Could not save torrent metadata. Retry after checking disk access."); _exports.erase(ex); }
			if (_transfers.count(key)) _transfers[key].error = "Could not save resume data. Check Application Support disk access.";
			_saveError = "Resume data could not be saved. Check disk access before quitting.";
		} else if (auto *r = lt::alert_cast<lt::cache_flushed_alert>(a)) {
			auto key = [self identifier:r->handle]; if (_transfers.count(key)) _transfers[key].flushed = true;
		} else if (auto *r = lt::alert_cast<lt::storage_moved_alert>(a)) {
			auto key = [self identifier:r->handle]; if (!_transfers.count(key)) continue;
			auto& t = _transfers[key]; t.moving = false; t.error.clear(); [self persistPaths:key transfer:t]; [self save:t];
			[_events addObject:@{@"kind":@"moved", @"id":str(key), @"path":str(r->storage_path())}];
		} else if (auto *r = lt::alert_cast<lt::storage_moved_failed_alert>(a)) {
			auto key = [self identifier:r->handle]; if (!_transfers.count(key)) continue;
			_transfers[key].moving = false; _transfers[key].error = "Move failed. Check destination access and free space, then Retry Move.";
			[_events addObject:@{@"kind":@"moveFailed", @"id":str(key)}];
		} else if (auto *r = lt::alert_cast<lt::file_renamed_alert>(a)) {
			auto key = [self identifier:r->handle]; if (!_transfers.count(key)) continue;
			auto& t = _transfers[key]; t.renaming.erase(int(r->index)); [self persistPaths:key transfer:t]; [self save:t];
		} else if (auto *r = lt::alert_cast<lt::file_rename_failed_alert>(a)) {
			auto key = [self identifier:r->handle]; if (!_transfers.count(key)) continue;
			auto& t = _transfers[key]; t.renaming.erase(int(r->index)); t.error = "Some paths could not be renamed. Review the current file paths before resuming."; [self persistPaths:key transfer:t]; [self save:t];
		} else if (auto *r = lt::alert_cast<lt::metadata_received_alert>(a)) {
			auto key = [self identifier:r->handle];
			if (_transfers.count(key)) {
				auto ti = r->handle.torrent_file();
				if (ti && ti->priv()) r->handle.set_flags(lt::torrent_flags::disable_dht | lt::torrent_flags::disable_pex | lt::torrent_flags::disable_lsd);
				[self persistPaths:key transfer:_transfers[key]];
				[self save:_transfers[key]];
			}
		} else if (auto *r = lt::alert_cast<lt::torrent_conflict_alert>(a)) {
			auto first = [self identifier:r->handle], second = [self identifier:r->conflicting_torrent];
			if (!_transfers.count(first) || !_transfers.count(second)) continue;
			if (_transfers[first].order > _transfers[second].order) std::swap(first, second);
			auto& existing = _transfers[first];
			lt::add_torrent_params params; params.ti = r->metadata; params.save_path = existing.handle.status().save_path;
			params.flags &= ~lt::torrent_flags::auto_managed; params.flags |= lt::torrent_flags::paused;
			if (!_pex) params.flags |= lt::torrent_flags::disable_pex;
			if (params.ti->priv()) params.flags |= lt::torrent_flags::disable_dht | lt::torrent_flags::disable_pex | lt::torrent_flags::disable_lsd;
			writeFile(_storage + "/" + first + ".torrent", lt::write_torrent_file_buf(params, lt::write_flags::allow_missing_piece_layer));
			_session->remove_torrent(existing.handle); _session->remove_torrent(_transfers[second].handle);
			existing.handle = _session->add_torrent(params); existing.handle.set_max_connections(_torrentPeers); existing.error.clear();
			_transfers.erase(second); [self persistPaths:first transfer:existing]; [self save:existing];
			for (auto const& suffix : {".torrent", ".resume", ".paths.json"}) fs::remove(_storage + "/" + second + suffix);
			[_events addObject:@{@"kind":@"duplicate", @"id":str(second), @"existingID":str(first)}];
		} else if (auto *r = lt::alert_cast<lt::listen_succeeded_alert>(a)) {
			if (_requestedPort && r->port != _requestedPort) continue;
			_boundPort = r->port;
			if (r->socket_type == lt::socket_type_t::utp) _udpBound = true;
		} else if (lt::alert_cast<lt::listen_failed_alert>(a)) {
			_networkError = "Listening socket failed. Choose another port and check firewall settings.";
		} else if (lt::alert_cast<lt::portmap_error_alert>(a)) {
			_networkError = "Automatic router mapping failed. Configure port forwarding on your router.";
		} else if (auto *r = lt::alert_cast<lt::torrent_error_alert>(a)) {
			auto key = [self identifier:r->handle]; if (_transfers.count(key)) _transfers[key].error = "Transfer failed: " + r->error.message();
		}
	} catch (std::exception const& e) {
		_saveError = "Could not persist engine state. Check Application Support access and free disk space.";
		if (auto *ta = dynamic_cast<lt::torrent_alert *>(a)) {
			auto key = [self identifier:ta->handle];
			if (_transfers.count(key)) _transfers[key].error = _saveError;
			auto ex = _exports.find(key); if (ex != _exports.end()) { ex->second(nil, @"Export failed. Check metadata availability and disk access, then retry."); _exports.erase(ex); }
		}
	} }
}
- (double)creationProgress { return _creationProgress.load(); }
- (void)cancelCreation { _cancel.store(true); }
- (void)perform:(NSString *)command payload:(NSData *)payload completion:(void (^)(NSData *, NSString *))completion {
	if ([command isEqual:@"create"]) { _cancel = false; _creationProgress = 0; }
	dispatch_async(_queue, ^{
		@autoreleasepool { try {
			[self ensureSession]; [self drain];
			NSDictionary *p = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
			if (![p isKindOfClass:NSDictionary.class]) throw std::runtime_error("Invalid engine command.");
			if ([command isEqual:@"add"]) {
				std::string key = cpp(p[@"id"]), source = cpp(p[@"source"]);
				lt::error_code ec; lt::add_torrent_params params;
				auto resume = readFile(_storage + "/" + key + ".resume");
				if ([p[@"restore"] boolValue] && !resume.empty()) params = lt::read_resume_data(resume, ec);
				if (ec) { ec.clear(); params = {}; }
				if (!params.ti) {
					if (source.rfind("magnet:", 0) == 0) params = lt::parse_magnet_uri(source, ec);
					else params.ti = std::make_shared<lt::torrent_info>(source, ec);
				}
				if (ec) throw std::runtime_error("Invalid torrent metadata or magnet link: " + ec.message());
				auto ih = params.ti ? params.ti->info_hashes() : params.info_hashes;
				for (auto const& [existing, t] : _transfers) {
					auto other = t.handle.info_hashes();
					if ((ih.has_v1() && other.has_v1() && ih.v1 == other.v1) || (ih.has_v2() && other.has_v2() && ih.v2 == other.v2)) {
						completion(json(@{@"id":str(existing), @"duplicate":@YES}), nil); return;
					}
				}
				params.save_path = cpp(p[@"destination"]);
				bool interruptedRename = false;
				if ([p[@"restore"] boolValue] && params.ti && fs::exists(_storage + "/" + key + ".paths.json")) {
					auto bytes = readFile(_storage + "/" + key + ".paths.json");
					NSDictionary *journal = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes.data() length:bytes.size()] options:0 error:nil];
					if (![journal isKindOfClass:NSDictionary.class]) throw std::runtime_error("Saved path mappings are unreadable. Restore state.json and the Engine folder from a backup.");
					interruptedRename = [journal[@"reviewRequired"] boolValue];
					NSString *destination = journal[@"destination"];
					if (destination.length && fs::path(cpp(destination)).is_absolute()) params.save_path = cpp(destination);
					for (NSDictionary *entry in journal[@"paths"]) {
						int index = [entry[@"index"] intValue]; auto path = cpp(entry[@"path"]);
						if (index < 0 || index >= params.ti->num_files() || !safeRelative(path)) throw std::runtime_error("Saved path mapping is unsafe. Review the saved engine state before resuming.");
						params.renamed_files[lt::file_index_t(index)] = path;
					}
					for (NSDictionary *entry in journal[@"pending"]) {
						int index = [entry[@"index"] intValue]; auto target = cpp(entry[@"path"]);
						if (index < 0 || index >= params.ti->num_files() || !safeRelative(target)) throw std::runtime_error("Saved rename journal is unsafe.");
						auto fileIndex = lt::file_index_t(index); auto old = params.renamed_files[fileIndex];
						bool oldExists = fs::exists(fs::path(params.save_path) / old), newExists = fs::exists(fs::path(params.save_path) / target);
						if (!oldExists || old == target) params.renamed_files[fileIndex] = target;
						else if (newExists) throw std::runtime_error("Interrupted rename has conflicting files. Review both local paths before restoring this transfer.");
						interruptedRename = true;
					}
				}
				fs::create_directories(params.save_path);
				params.flags &= ~lt::torrent_flags::auto_managed;
				params.flags |= lt::torrent_flags::paused;
				if (!_pex) params.flags |= lt::torrent_flags::disable_pex;
				if (params.ti && params.ti->priv()) params.flags |= lt::torrent_flags::disable_dht | lt::torrent_flags::disable_pex | lt::torrent_flags::disable_lsd;
				NSString *tracker = p[@"tracker"];
				if (tracker.length && params.ti && !params.ti->priv()) params.trackers.push_back(cpp(tracker));
				NSArray *selected = p[@"selected"];
				if (selected.count) for (NSNumber *v in selected) params.file_priorities.push_back(lt::download_priority_t(v.intValue ? 4 : 0));
				// Copy the source before publishing the handle. No import may depend on the original.
				if (source.rfind("magnet:", 0) != 0 && source != _storage + "/" + key + ".torrent") {
					auto bytes = readFile(source); if (bytes.empty()) throw std::runtime_error("Cannot read the torrent file.");
					writeFile(_storage + "/" + key + ".torrent", bytes);
				}
				auto handle = _session->add_torrent(params, ec);
				if (ec) throw std::runtime_error("Cannot add torrent: " + ec.message());
				handle.set_max_connections(_torrentPeers);
				Transfer t; t.handle = handle;
				t.order = _nextOrder++;
				if (interruptedRename) t.error = "An interrupted rename was reconciled with local files. Review current names, then Start to resume.";
				if (params.ti) for (auto i : params.ti->layout().file_range()) t.original.push_back(params.ti->layout().file_path(i));
				_transfers[key] = std::move(t);
				try { [self persistPaths:key transfer:_transfers[key]]; [self save:_transfers[key]]; }
				catch (...) { _session->remove_torrent(handle); _transfers.erase(key); throw; }
				completion(json(@{@"id":str(key), @"duplicate":@NO, @"hashes":hashes(ih)}), nil); return;
			}
			if ([command isEqual:@"inspect"]) {
				lt::error_code ec; auto ti = std::make_shared<lt::torrent_info>(cpp(p[@"source"]), ec);
				if (ec) throw std::runtime_error("Cannot read torrent: " + ec.message());
				NSMutableArray *files = [NSMutableArray array];
				for (auto i : ti->layout().file_range()) [files addObject:@{@"index":@(int(i)), @"path":str(ti->layout().file_path(i)), @"size":@(ti->layout().file_size(i)), @"pad":@(ti->layout().pad_file_at(i))}];
				completion(json(@{@"name":str(ti->name()), @"private":@(ti->priv()), @"files":files, @"hashes":hashes(ti->info_hashes())}), nil); return;
			}
			if ([command isEqual:@"settings"]) {
				lt::settings_pack s;
				if (p[@"allowSameIP"]) s.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, [p[@"allowSameIP"] boolValue]);
				s.set_bool(lt::settings_pack::enable_incoming_utp, [p[@"utp"] boolValue]); s.set_bool(lt::settings_pack::enable_outgoing_utp, [p[@"utp"] boolValue]);
				if (p[@"tcp"]) { s.set_bool(lt::settings_pack::enable_incoming_tcp, [p[@"tcp"] boolValue]); s.set_bool(lt::settings_pack::enable_outgoing_tcp, [p[@"tcp"] boolValue]); }
				s.set_bool(lt::settings_pack::enable_dht, [p[@"dht"] boolValue]); s.set_bool(lt::settings_pack::enable_lsd, [p[@"lsd"] boolValue]);
				bool mapping = p[@"mapping"] ? [p[@"mapping"] boolValue] : true;
				s.set_bool(lt::settings_pack::enable_upnp, mapping); s.set_bool(lt::settings_pack::enable_natpmp, mapping);
				s.set_int(lt::settings_pack::connections_limit, std::max(1, [p[@"peers"] intValue]));
				int port = [p[@"port"] intValue]; if (port < 0 || port > 65535) throw std::runtime_error("Port must be between 1 and 65535, or zero for automatic selection.");
				if (port == 0) {
					int fd = socket(AF_INET, SOCK_STREAM, 0); if (fd < 0) throw std::runtime_error("Cannot allocate a listening socket.");
					sockaddr_in addr{}; addr.sin_family = AF_INET; addr.sin_addr.s_addr = INADDR_ANY;
					if (bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr))) { close(fd); throw std::runtime_error("Cannot select a free port."); }
					socklen_t len = sizeof(addr); getsockname(fd, reinterpret_cast<sockaddr *>(&addr), &len); port = ntohs(addr.sin_port); close(fd);
				}
				if (_requestedPort != port) { _boundPort = 0; _udpBound = false; _networkError.clear(); } _requestedPort = port;
				s.set_bool(lt::settings_pack::listen_system_port_fallback, false); s.set_int(lt::settings_pack::max_retry_port_bind, 0);
				auto address = std::string("0.0.0.0:") + std::to_string(port);

				if (port != 0) address += ",[::]:" + std::to_string(port);
				s.set_str(lt::settings_pack::listen_interfaces, address); _session->apply_settings(s); _pex = [p[@"pex"] boolValue];
				_torrentPeers = std::max(1, std::min([p[@"torrentPeers"] intValue], [p[@"peers"] intValue]));
				for (auto& [key, t] : _transfers) {
					t.handle.set_max_connections(std::max(1, std::min([p[@"torrentPeers"] intValue], [p[@"peers"] intValue])));
					auto ti = t.handle.torrent_file();
					if (!_pex || (ti && ti->priv())) t.handle.set_flags(lt::torrent_flags::disable_pex); else t.handle.unset_flags(lt::torrent_flags::disable_pex);
				}
				completion(json(@{@"port":@(port)}), nil); return;
			} else if ([command isEqual:@"blocklist"]) {
				lt::ip_filter filter;
				for (NSDictionary *range in p[@"ranges"]) {
					lt::error_code ec; auto first = lt::make_address(cpp(range[@"first"]), ec); if (ec) throw std::runtime_error("Invalid blocklist address.");
					auto last = lt::make_address(cpp(range[@"last"]), ec); if (ec) throw std::runtime_error("Invalid blocklist address.");
					filter.add_rule(first, last, lt::ip_filter::blocked);
				} _session->set_ip_filter(filter);
			} else if ([command isEqual:@"shutdown"]) {
				_saveError.clear();
				for (auto& [key, t] : _transfers) { t.handle.pause(); [self save:t]; }
				auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
				while (_pendingResume > 0 && std::chrono::steady_clock::now() < deadline) { _session->wait_for_alert(lt::milliseconds(100)); [self drain]; }
				if (!_saveError.empty()) throw std::runtime_error(_saveError);
				if (_pendingResume) throw std::runtime_error("Resume data has not finished saving. Please try quitting again.");
			} else if ([command isEqual:@"create"]) {
				std::string source = cpp(p[@"source"]);
				auto files = lt::list_files(source, [](std::string const& path) { return !fs::is_symlink(path); });
				lt::create_torrent creator(std::move(files)); // Default generates both v1 and v2 metadata.
				creator.set_priv([p[@"private"] boolValue]);
				NSArray *trackers = p[@"trackers"];
				if ([p[@"private"] boolValue] && !trackers.count) throw std::runtime_error("A private torrent requires at least one tracker.");
				for (NSString *tracker in trackers) creator.add_tracker(cpp(tracker));
				lt::error_code ec;
				lt::set_piece_hashes(creator, fs::path(source).parent_path().string(), [&](lt::piece_index_t i) { if (_cancel) throw std::runtime_error("Creation cancelled."); _creationProgress = double(int(i) + 1) / creator.num_pieces(); }, ec);
				if (_cancel) throw std::runtime_error("Creation cancelled.");
				if (ec) throw std::runtime_error("Cannot hash source: " + ec.message());
				std::vector<char> bytes; lt::bencode(std::back_inserter(bytes), creator.generate());
				std::string output = _storage + "/" + cpp(p[@"id"]) + ".torrent"; writeFile(output, bytes);
				completion(json(@{@"source":str(output), @"destination":str(fs::path(source).parent_path().string())}), nil); return;
			} else {
				auto key = cpp(p[@"id"]); auto it = _transfers.find(key);
				if (it == _transfers.end()) throw std::runtime_error("Transfer no longer exists.");
				auto& t = it->second; auto h = t.handle;
				if ([command isEqual:@"run"]) {
					if ([p[@"running"] boolValue] && t.renaming.empty() && !t.moving && t.error.empty()) h.resume(); else h.pause();
					if (p[@"downloadLimit"]) h.set_download_limit([p[@"downloadLimit"] intValue]);
					if (p[@"uploadLimit"]) h.set_upload_limit([p[@"uploadLimit"] intValue]);
				} else if ([command isEqual:@"pause"]) { h.pause(); [self save:t]; }
				else if ([command isEqual:@"retry"]) { t.error.clear(); h.clear_error(); [self persistPaths:key transfer:t]; }
				else if ([command isEqual:@"save"]) { [self save:t]; }
				else if ([command isEqual:@"recheck"]) { t.error.clear(); h.force_recheck(); }
				else if ([command isEqual:@"connect"]) { h.connect_peer({lt::make_address(cpp(p[@"address"])), static_cast<unsigned short>([p[@"port"] intValue])}); }
				else if ([command isEqual:@"select"]) {
					std::vector<lt::download_priority_t> priorities; for (NSNumber *v in p[@"selected"]) priorities.push_back(lt::download_priority_t(v.intValue ? 4 : 0));
					h.prioritize_files(priorities); [self save:t];
				} else if ([command isEqual:@"move"]) {
					fs::create_directories(cpp(p[@"destination"])); t.error.clear(); t.moving = true;
					h.move_storage(cpp(p[@"destination"]), lt::move_flags_t::fail_if_exist);
				} else if ([command isEqual:@"magnet"]) {
					lt::add_torrent_params magnet; magnet.info_hashes = h.info_hashes(); magnet.name = h.status().name;
					for (auto const& tracker : h.trackers()) magnet.trackers.push_back(tracker.url);
					completion(json(@{@"magnet":str(lt::make_magnet_uri(magnet))}), nil); return;
				}
				else if ([command isEqual:@"export"]) {
					if (!h.torrent_file()) throw std::runtime_error("Metadata is still resolving.");
					_exports[key] = [completion copy]; [self save:t]; return;
				} else if ([command isEqual:@"tracker"]) {
					auto ti = h.torrent_file(); if (!ti || ti->priv()) throw std::runtime_error("Trackers cannot be appended to this torrent.");
					h.add_tracker(lt::announce_entry(cpp(p[@"tracker"]))); [self save:t];
				} else if ([command isEqual:@"rename"]) {
					auto ti = h.torrent_file(); if (!ti) throw std::runtime_error("Metadata is still resolving.");
					auto renames = h.get_renamed_files(); lt::filenames current(ti->layout(), renames);
					std::set<std::string> targets; std::set<int> indices;
					NSArray *changes = p[@"changes"];
					for (NSDictionary *change in changes) indices.insert([change[@"index"] intValue]);
					for (NSDictionary *change in changes) {
						int index = [change[@"index"] intValue]; std::string path = cpp(change[@"path"]);
						fs::path relative(path);
						if (index < 0 || index >= ti->num_files() || !safeRelative(path)) throw std::runtime_error("Invalid or unsafe relative path.");
						if (!targets.insert(path).second) throw std::runtime_error("Rename paths collide.");
						for (auto i : ti->layout().file_range()) if (!indices.count(int(i)) && current.file_path(i) == path) throw std::runtime_error("A torrent file already has that path.");
						auto dest = fs::path(h.status().save_path) / relative;
						if (fs::exists(dest) && path != current.file_path(lt::file_index_t(index))) throw std::runtime_error("A file already exists at the new path.");
						auto base = fs::weakly_canonical(h.status().save_path); auto resolved = fs::weakly_canonical(dest.parent_path());
						auto rel = resolved.lexically_relative(base); if (rel.empty() || *rel.begin() == "..") throw std::runtime_error("Rename escapes the destination.");
					}
					h.pause(); t.error.clear();
					for (NSDictionary *change in changes) t.renaming[[change[@"index"] intValue]] = cpp(change[@"path"]);
					try { [self persistPaths:key transfer:t]; } catch (...) { t.renaming.clear(); throw; }
					for (auto const& [index, path] : t.renaming) h.rename_file(lt::file_index_t(index), path);
				} else if ([command isEqual:@"remove"]) {
					NSMutableArray *trashed = [NSMutableArray array];
					// Swift handles confirmation. Trash only regular managed files, never directories.
					if ([p[@"trash"] boolValue]) {
						auto ti = h.torrent_file(); if (!ti) throw std::runtime_error("Cannot safely delete files without metadata.");
						h.pause(); t.flushed = false; h.flush_cache();
						auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
						while (!t.flushed && std::chrono::steady_clock::now() < deadline) { _session->wait_for_alert(lt::milliseconds(50)); [self drain]; }
						if (!t.flushed) throw std::runtime_error("Files are still in use. Wait for disk activity to finish and retry removal.");

						auto renames = h.get_renamed_files(); lt::filenames current(ti->layout(), renames);
						auto base = fs::weakly_canonical(h.status().save_path);
						std::vector<fs::path> managed;
						for (auto i : ti->layout().file_range()) {
							if (ti->layout().pad_file_at(i)) continue;
							auto file = fs::path(h.status().save_path) / current.file_path(i);
							auto resolved = fs::weakly_canonical(file); auto rel = resolved.lexically_relative(base);
							if (rel.empty() || *rel.begin() == ".." || fs::is_symlink(file) || fs::is_directory(file)) throw std::runtime_error("Unsafe managed path; files were retained. Review the save location.");
							for (auto const& [otherKey, other] : _transfers) if (otherKey != key) {
								auto otherInfo = other.handle.torrent_file(); if (!otherInfo) continue;
								auto otherRenames = other.handle.get_renamed_files(); lt::filenames otherCurrent(otherInfo->layout(), otherRenames);
								for (auto j : otherInfo->layout().file_range()) if (fs::weakly_canonical(fs::path(other.handle.status().save_path) / otherCurrent.file_path(j)) == resolved) throw std::runtime_error("A managed file is shared with another transfer. Remove without deleting data instead.");
							}
							if (fs::exists(file)) managed.push_back(file);
						}
						for (auto const& file : managed) {
							NSError *error = nil;
							NSURL *receipt = nil;
							if (![[NSFileManager defaultManager] trashItemAtURL:[NSURL fileURLWithPath:str(file.string())] resultingItemURL:&receipt error:&error])
								throw std::runtime_error("Trash operation failed; some managed files may already be in Trash. " + cpp(error.localizedDescription));
							if (receipt) [trashed addObject:receipt.path];
						}
					}
					_session->remove_torrent(h); _transfers.erase(it);
					fs::remove(_storage + "/" + key + ".resume"); fs::remove(_storage + "/" + key + ".torrent"); fs::remove(_storage + "/" + key + ".paths.json");
					completion(json(@{@"trashed":trashed}), nil); return;
				} else throw std::runtime_error("Unknown engine command.");
			}
			completion(json(@{}), nil);
		} catch (std::exception const& e) { completion(nil, str(e.what())); } }
	});
}
- (void)snapshot:(void (^)(NSData *, NSString *))completion {
	// Hash progress must remain observable while the serial engine queue is hashing.
	double progress = _creationProgress;
	dispatch_async(_queue, ^{ @autoreleasepool { try {
		[self ensureSession]; [self drain]; NSMutableArray *rows = [NSMutableArray array];
		for (auto& [key, t] : _transfers) {
			auto h = t.handle; auto s = h.status(lt::torrent_handle::query_pieces | lt::torrent_handle::query_name | lt::torrent_handle::query_save_path);
			auto ti = h.torrent_file(); NSMutableArray *files = [NSMutableArray array], *trackers = [NSMutableArray array], *peers = [NSMutableArray array], *pieces = [NSMutableArray array];
			if (ti) {
				auto renames = h.get_renamed_files(); lt::filenames current(ti->layout(), renames);
				if (t.original.empty()) for (auto i : ti->layout().file_range()) t.original.push_back(ti->layout().file_path(i));
				auto priorities = h.get_file_priorities(); auto done = h.file_progress(lt::torrent_handle::piece_granularity);
				for (auto i : ti->layout().file_range()) [files addObject:@{@"index":@(int(i)), @"path":str(current.file_path(i)), @"original":str(t.original.at(int(i))), @"size":@(ti->layout().file_size(i)), @"done":@(done.at(int(i))), @"selected":@(static_cast<std::uint8_t>(priorities.at(int(i))) > 0), @"pad":@(ti->layout().pad_file_at(i))}];
				std::vector<int> avail; h.piece_availability(avail); std::vector<lt::partial_piece_info> queue; h.get_download_queue(queue);
				std::set<int> downloading; for (auto const& p : queue) downloading.insert(int(p.piece_index));
				for (int i = 0; i < ti->num_pieces(); ++i) {
					int colour = 0;
					if (s.pieces.size() > i && s.pieces[lt::piece_index_t(i)]) colour = 1;
					else if (downloading.count(i)) colour = 2;
					else if (s.num_peers > 0 && i < int(avail.size())) colour = avail[i] ? 3 : 4;
					[pieces addObject:@(colour)];
				}
			}
			for (auto const& tracker : h.trackers()) {
				NSString *message = @"";
				for (auto const& ep : tracker.endpoints) for (auto const& info : ep.info_hashes) {
					if (info.last_error) message = str(info.last_error.message());
					if (!info.message.empty()) message = str(info.message);
				}
				[trackers addObject:@{@"url":str(tracker.url), @"message":message}];
			}
			std::vector<lt::peer_info> peerInfo; h.get_peer_info(peerInfo);
			for (auto const& peer : peerInfo) [peers addObject:@{@"address":str(peer.remote_endpoint().address().to_string()), @"client":str(peer.client), @"down":@(peer.down_speed), @"up":@(peer.up_speed), @"utp":@((peer.flags & lt::peer_info::utp_socket) != lt::peer_flags_t{})}];
			bool demand = false; for (auto const& peer : peerInfo) if ((peer.flags & lt::peer_info::remote_interested) != lt::peer_flags_t{}) demand = true;
			NSString *state = @"Downloading";
			if (!s.has_metadata) state = @"Resolving metadata";
			else if (s.state == lt::torrent_status::checking_files || s.state == lt::torrent_status::checking_resume_data) state = @"Checking";
			else if (s.is_finished) state = @"Seeding";
			if (s.flags & lt::torrent_flags::paused) state = @"Paused";
			if (t.moving) state = @"Moving";
			if (!t.renaming.empty()) state = @"Renaming";
			if (s.errc) t.error = "Transfer error: " + s.errc.message();
			[rows addObject:@{@"id":str(key), @"name":str(s.name), @"path":str(s.save_path), @"state":state, @"error":str(t.error), @"metadata":@(s.has_metadata), @"private":@(ti && ti->priv()), @"complete":@(s.is_finished), @"progress":@(s.progress), @"wanted":@(s.total_wanted), @"done":@(s.total_wanted_done), @"total":@(ti ? ti->total_size() : 0), @"down":@(s.download_payload_rate), @"up":@(s.upload_payload_rate), @"downloaded":@(s.all_time_download), @"uploaded":@(s.all_time_upload), @"demand":@(demand), @"hashes":hashes(h.info_hashes()), @"pieces":pieces, @"files":files, @"trackers":trackers, @"peers":peers}];
		}
		NSData *result = json(@{@"transfers":rows, @"events":[_events copy], @"port":@(_boundPort), @"udp":@(_udpBound), @"networkError":str(_networkError), @"creationProgress":@(progress)});
		[_events removeAllObjects]; completion(result, nil);
	} catch (std::exception const& e) { completion(nil, str(e.what())); } } });
}
@end
