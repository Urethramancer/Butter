#import <Foundation/Foundation.h>
#include <libtorrent/session.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/settings_pack.hpp>
#include <csignal>
#include <thread>
#include <chrono>
#include <stdexcept>
namespace lt = libtorrent;
static volatile sig_atomic_t stopping = 0;
static void stop(int) { stopping = 1; }
static void require(bool value, char const* message) { if (!value) throw std::runtime_error(message); }
static void publish(NSDictionary* record, NSString* path) {
	NSError* error = nil;
	NSData* bytes = [NSJSONSerialization dataWithJSONObject:record options:0 error:&error];
	require(bytes && [bytes writeToFile:path options:NSDataWritingAtomic error:&error], "Cannot publish reference status");
}
static void create(NSString* root) {
	NSFileManager* fm = NSFileManager.defaultManager;
	NSString* seed = [root stringByAppendingPathComponent:@"reference-seed"];
	require([fm createDirectoryAtPath:[seed stringByAppendingPathComponent:@"Bundle/nested"] withIntermediateDirectories:YES attributes:nil error:nil], "Cannot create reference source");
	for (auto const& entry : std::vector<std::pair<NSString*, int>>{{@"single.bin", 300003}, {@"Bundle/a.bin", 10003}, {@"Bundle/nested/b.bin", 300019}, {@"Bundle/empty", 0}}) {
		NSMutableData* data = [NSMutableData dataWithLength:entry.second];
		for (NSUInteger offset = 0; offset < data.length; ++offset) ((unsigned char*)data.mutableBytes)[offset] = (offset * 71 + offset / 97) % 251;
		require([data writeToFile:[seed stringByAppendingPathComponent:entry.first] atomically:YES], "Cannot write reference source");
	}
	for (bool multi : {false, true}) for (int size : {16384, 65536}) {
		NSString* name = [NSString stringWithFormat:@"%@-%d.torrent", multi ? @"multi" : @"single", size];
		NSString* source = [seed stringByAppendingPathComponent:multi ? @"Bundle" : @"single.bin"];
		lt::create_torrent creator(lt::list_files(source.UTF8String), size, lt::create_torrent::v1_only);
		creator.set_priv(multi);
		lt::error_code error; lt::set_piece_hashes(creator, seed.UTF8String, error); require(!error, "Reference hashing failed");
		std::vector<char> bytes; lt::bencode(std::back_inserter(bytes), creator.generate());
		require([[NSData dataWithBytes:bytes.data() length:bytes.size()] writeToFile:[root stringByAppendingPathComponent:name] atomically:YES], "Cannot publish reference metadata");
	}
}
int main(int argc, char** argv) { @autoreleasepool { try {
	require(argc == 3, "Expected --create directory or --run job.json");
	NSString* path = [NSString stringWithUTF8String:argv[2]];
	if (std::string(argv[1]) == "--create") { create(path); return 0; }
	require(std::string(argv[1]) == "--run", "Unknown reference operation");
	NSDictionary* job = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
	require(job != nil, "Cannot read reference job");
	std::signal(SIGTERM, stop); std::signal(SIGINT, stop);
	lt::settings_pack settings;
	settings.set_str(lt::settings_pack::listen_interfaces, [job[@"listen"] UTF8String]);
	for (auto setting : {lt::settings_pack::enable_dht, lt::settings_pack::enable_lsd, lt::settings_pack::enable_upnp, lt::settings_pack::enable_natpmp, lt::settings_pack::enable_incoming_utp, lt::settings_pack::enable_outgoing_utp}) settings.set_bool(setting, false);
	settings.set_bool(lt::settings_pack::enable_incoming_tcp, true); settings.set_bool(lt::settings_pack::enable_outgoing_tcp, true);
	settings.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, true);
	settings.set_int(lt::settings_pack::in_enc_policy, lt::settings_pack::pe_disabled); settings.set_int(lt::settings_pack::out_enc_policy, lt::settings_pack::pe_disabled);
	settings.set_int(lt::settings_pack::alert_mask, static_cast<std::uint32_t>(lt::alert_category::error | lt::alert_category::storage | lt::alert_category::status));
	lt::session session(settings);
	lt::error_code error;
	lt::add_torrent_params params;
	params.ti = std::make_shared<lt::torrent_info>([job[@"torrent"] UTF8String], error); require(!error, "Reference rejected torrent metadata");
	params.save_path = [job[@"destination"] UTF8String]; params.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
	if (NSArray* selected = job[@"selected"]) for (NSNumber* value in selected) params.file_priorities.push_back(value.boolValue ? lt::default_priority : lt::dont_download);
	auto handle = session.add_torrent(params, error); require(!error, "Cannot add reference torrent");
	bool connected = false;
	auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(45);
	while (!stopping && std::chrono::steady_clock::now() < deadline) {
		auto status = handle.status(); require(!status.errc, status.errc.message().c_str());
		if (!connected && [job[@"remotePort"] intValue] && status.state != lt::torrent_status::checking_files && status.state != lt::torrent_status::checking_resume_data) {
			handle.connect_peer({lt::make_address([job[@"remoteHost"] UTF8String]), static_cast<unsigned short>([job[@"remotePort"] intValue])}); connected = true;
		}
		publish(@{@"port":@(session.listen_port()), @"complete":@(status.is_finished), @"seeding":@(status.is_seeding),
			@"downloaded":@(status.total_payload_download), @"uploaded":@(status.total_payload_upload), @"done":@(status.total_wanted_done), @"wanted":@(status.total_wanted)}, job[@"status"]);
		std::this_thread::sleep_for(std::chrono::milliseconds(20));
	}
	require(stopping, "Reference job exceeded its bounded lifetime");
	handle.pause(); handle.flush_cache();
	bool flushed = false;
	deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
	while (!flushed && std::chrono::steady_clock::now() < deadline) {
		session.wait_for_alert(lt::milliseconds(20)); std::vector<lt::alert*> alerts; session.pop_alerts(&alerts);
		for (auto alert : alerts) if (lt::alert_cast<lt::cache_flushed_alert>(alert)) flushed = true;
	}
	require(flushed, "Reference flush barrier timed out"); return 0;
} catch (std::exception const& error) { fprintf(stderr, "FAIL: %s\n", error.what()); return 1; } } }
