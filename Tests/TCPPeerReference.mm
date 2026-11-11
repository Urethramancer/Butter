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
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/extensions.hpp>
#include <csignal>
#include <thread>
#include <chrono>
#include <stdexcept>
#include <iostream>
#include <set>
namespace lt = libtorrent;
// Introducers exchange discovery messages while never supplying torrent payload.
struct NoPayloadPeer : lt::peer_plugin { bool on_request(lt::peer_request const&) override { return true; } };
struct NoPayloadTorrent : lt::torrent_plugin {
	std::shared_ptr<lt::peer_plugin> new_connection(lt::peer_connection_handle const&) override { return std::make_shared<NoPayloadPeer>(); }
};
static volatile sig_atomic_t stopping = 0;
static void stop(int) { stopping = 1; }
static void require(bool value, char const* message) { if (!value) throw std::runtime_error(message); }
#include "TransferBenchmarkReference.hpp"
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
	for (int version : {1, 2, 3}) for (bool multi : {false, true}) for (int size : {16384, 65536}) {
		NSString* suffix = version == 1 ? @"" : version == 2 ? @"-v2" : @"-hybrid";
		NSString* name = [NSString stringWithFormat:@"%@-%d%@.torrent", multi ? @"multi" : @"single", size, suffix];
		NSString* source = [seed stringByAppendingPathComponent:multi ? @"Bundle" : @"single.bin"];
		lt::create_flags_t flags = version == 1 ? lt::create_torrent::v1_only : version == 2 ? lt::create_torrent::v2_only : lt::create_flags_t{};
		lt::create_torrent creator(lt::list_files(source.UTF8String), size, flags);
		creator.set_priv(multi);
		lt::error_code error; lt::set_piece_hashes(creator, seed.UTF8String, error); require(!error, "Reference hashing failed");
		std::vector<char> bytes; lt::bencode(std::back_inserter(bytes), creator.generate());
		require([[NSData dataWithBytes:bytes.data() length:bytes.size()] writeToFile:[root stringByAppendingPathComponent:name] atomically:YES], "Cannot publish reference metadata");
	}
}
static void dht(NSDictionary* job) {
	lt::settings_pack settings;
	settings.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
	settings.set_str(lt::settings_pack::dht_bootstrap_nodes, "");
	for (auto setting : {lt::settings_pack::enable_lsd, lt::settings_pack::enable_upnp, lt::settings_pack::enable_natpmp,
		lt::settings_pack::dht_restrict_routing_ips, lt::settings_pack::dht_restrict_search_ips, lt::settings_pack::dht_ignore_dark_internet}) settings.set_bool(setting, false);
	settings.set_bool(lt::settings_pack::enable_dht, true);
	settings.set_int(lt::settings_pack::alert_mask, static_cast<std::uint32_t>(lt::alert_category::dht | lt::alert_category::dht_operation | lt::alert_category::error));
	lt::session session(settings);
	NSData* bytes = [[NSData alloc] initWithBase64EncodedString:job[@"hash"] options:0]; require(bytes.length == 20, "Expected 20-byte DHT hash");
	lt::sha1_hash hash(static_cast<char const*>(bytes.bytes));
	if ([job[@"remotePort"] intValue]) session.add_dht_node({"127.0.0.1", [job[@"remotePort"] intValue]});
	int announces = 0, routing = 0; bool searched = false;
	NSMutableSet<NSNumber*>* peers = [NSMutableSet set];
	auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(45);
	while (!stopping && std::chrono::steady_clock::now() < deadline) {
		session.post_dht_stats(); session.wait_for_alert(lt::milliseconds(20));
		std::vector<lt::alert*> alerts; session.pop_alerts(&alerts);
		for (auto alert : alerts) {
			if (auto stats = lt::alert_cast<lt::dht_stats_alert>(alert)) { routing = 0; for (auto const& bucket : stats->routing_table) routing += bucket.num_nodes; }
			if (auto announce = lt::alert_cast<lt::dht_announce_alert>(alert)) { if (announce->info_hash == hash) ++announces; }
			if (auto reply = lt::alert_cast<lt::dht_get_peers_reply_alert>(alert)) { if (reply->info_hash == hash) for (auto const& peer : reply->peers()) [peers addObject:@(peer.port())]; }
		}
		if (routing > 0 && !searched && [job[@"remotePort"] intValue]) {
			session.dht_get_peers(hash); session.dht_announce(hash, [job[@"announcePort"] intValue]); searched = true;
		}
		publish(@{@"port":@(session.listen_port()), @"ready":@(session.is_dht_running()), @"announces":@(announces), @"routing":@(routing), @"peers":peers.allObjects}, job[@"status"]);
		std::this_thread::sleep_for(std::chrono::milliseconds(20));
	}
	require(stopping, "DHT reference exceeded its bounded lifetime");
}
int main(int argc, char** argv) { @autoreleasepool { try {
	require(argc == 3, "Expected --create directory or --run job.json");
	NSString* path = [NSString stringWithUTF8String:argv[2]];
	if (std::string(argv[1]) == "--benchmark" || std::string(argv[1]) == "--verify") {
		NSDictionary* job = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
		require(job != nil, "Cannot read benchmark job"); benchmark(job, std::string(argv[1]) == "--verify"); return 0;
	}
	if (std::string(argv[1]) == "--create") { create(path); return 0; }
	if (std::string(argv[1]) == "--dht") {
		NSDictionary* job = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil]; require(job != nil, "Cannot read DHT job");
		std::signal(SIGTERM, stop); std::signal(SIGINT, stop); dht(job); return 0;
	}
	require(std::string(argv[1]) == "--run", "Unknown reference operation");
	NSDictionary* job = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
	require(job != nil, "Cannot read reference job");
	std::signal(SIGTERM, stop); std::signal(SIGINT, stop);
	lt::settings_pack settings;
	settings.set_str(lt::settings_pack::listen_interfaces, [job[@"listen"] UTF8String]);
	for (auto setting : {lt::settings_pack::enable_dht, lt::settings_pack::enable_lsd, lt::settings_pack::enable_upnp, lt::settings_pack::enable_natpmp, lt::settings_pack::enable_incoming_utp, lt::settings_pack::enable_outgoing_utp}) settings.set_bool(setting, false);
	settings.set_bool(lt::settings_pack::enable_incoming_tcp, true); settings.set_bool(lt::settings_pack::enable_outgoing_tcp, true);
	bool utp = [job[@"transport"] isEqualToString:@"utp"];
	settings.set_bool(lt::settings_pack::enable_lsd, [job[@"lsd"] boolValue]);
	bool dhtEnabled = [job[@"dht"] boolValue] || [job[@"dhtPort"] intValue] > 0;
	if (dhtEnabled) {
		settings.set_bool(lt::settings_pack::enable_dht, true); settings.set_str(lt::settings_pack::dht_bootstrap_nodes, "");
		for (auto setting : {lt::settings_pack::dht_restrict_routing_ips, lt::settings_pack::dht_restrict_search_ips, lt::settings_pack::dht_ignore_dark_internet}) settings.set_bool(setting, false);
	}
	settings.set_bool(lt::settings_pack::enable_incoming_tcp, !utp); settings.set_bool(lt::settings_pack::enable_outgoing_tcp, !utp);
	settings.set_bool(lt::settings_pack::enable_incoming_utp, utp); settings.set_bool(lt::settings_pack::enable_outgoing_utp, utp);
	settings.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, true);
	settings.set_bool(lt::settings_pack::close_redundant_connections, false);
	NSString* encryption = job[@"encryption"] ?: @"disabled";
	int policy = [encryption isEqualToString:@"disabled"] ? lt::settings_pack::pe_disabled : [encryption isEqualToString:@"fallback"] ? lt::settings_pack::pe_enabled : lt::settings_pack::pe_forced;
	settings.set_int(lt::settings_pack::in_enc_policy, policy); settings.set_int(lt::settings_pack::out_enc_policy, policy);
	settings.set_int(lt::settings_pack::allowed_enc_level, [encryption isEqualToString:@"rc4"] ? lt::settings_pack::pe_rc4 : lt::settings_pack::pe_both);
	settings.set_bool(lt::settings_pack::prefer_rc4, [encryption isEqualToString:@"prefer-rc4"]);
	bool diagnostics = [job[@"diagnostics"] boolValue];
	settings.set_int(lt::settings_pack::alert_mask, static_cast<std::uint32_t>(lt::alert_category::error | lt::alert_category::storage | lt::alert_category::status | (dhtEnabled ? lt::alert_category::dht : lt::alert_category_t{}) | (diagnostics ? lt::alert_category::peer | lt::alert_category::connect : lt::alert_category_t{})));
	lt::session session(settings);
	if ([job[@"dhtPort"] intValue] > 0) session.add_dht_node({"127.0.0.1", [job[@"dhtPort"] intValue]});
	lt::error_code error;
	lt::add_torrent_params params;
	if (job[@"magnet"]) lt::parse_magnet_uri([job[@"magnet"] UTF8String], params, error);
	else params.ti = std::make_shared<lt::torrent_info>([job[@"torrent"] UTF8String], error);
	require(!error, "Reference rejected torrent metadata or magnet");
	params.save_path = [job[@"destination"] UTF8String]; params.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
	if (job[@"pex"] && ![job[@"pex"] boolValue]) params.flags |= lt::torrent_flags::disable_pex;
	if ([job[@"noPayload"] boolValue]) params.extensions.push_back([](lt::torrent_handle const&, lt::client_data_t) { return std::make_shared<NoPayloadTorrent>(); });
	if (NSArray* selected = job[@"selected"]) for (NSNumber* value in selected) params.file_priorities.push_back(value.boolValue ? lt::default_priority : lt::dont_download);
	auto handle = session.add_torrent(params, error); require(!error, "Cannot add reference torrent");
	bool connected = false, dhtAnnounced = false, lsdAnnounced = false; int dhtAnnounces = 0;
	NSMutableArray<NSString*>* peerErrors = [NSMutableArray array];
	auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(45);
	while (!stopping && std::chrono::steady_clock::now() < deadline) {
		auto status = handle.status(); require(!status.errc, status.errc.message().c_str());
		if (dhtEnabled || diagnostics) {
			if (dhtEnabled && !dhtAnnounced) session.post_dht_stats(); std::vector<lt::alert*> alerts; session.pop_alerts(&alerts);
			int contacts = 0; for (auto alert : alerts) if (auto stats = lt::alert_cast<lt::dht_stats_alert>(alert)) for (auto const& bucket : stats->routing_table) contacts += bucket.num_nodes;
			for (auto alert : alerts) if (lt::alert_cast<lt::dht_announce_alert>(alert)) ++dhtAnnounces;
			for (auto alert : alerts) if (lt::alert_cast<lt::peer_error_alert>(alert) || lt::alert_cast<lt::peer_disconnected_alert>(alert) || lt::alert_cast<lt::lsd_error_alert>(alert)) {
				if (peerErrors.count == 64) [peerErrors removeObjectAtIndex:0]; [peerErrors addObject:[NSString stringWithUTF8String:alert->message().c_str()]];
			}
			if (!dhtAnnounced && contacts > 0 && status.state != lt::torrent_status::checking_files && status.state != lt::torrent_status::checking_resume_data) { handle.force_dht_announce(); dhtAnnounced = true; }
		}
		if ([job[@"lsd"] boolValue] && !lsdAnnounced && session.listen_port() > 0 && status.has_metadata && status.state != lt::torrent_status::checking_files && status.state != lt::torrent_status::checking_resume_data) {
			handle.force_lsd_announce(); lsdAnnounced = true;
		}
		if (!connected && [job[@"remotePort"] intValue] && status.state != lt::torrent_status::checking_files && status.state != lt::torrent_status::checking_resume_data) {
			handle.connect_peer({lt::make_address([job[@"remoteHost"] UTF8String]), static_cast<unsigned short>([job[@"remotePort"] intValue])}); connected = true;
		}
		int rc4 = 0, negotiated = 0, utpPeers = 0, tcpPeers = 0, dhtPeers = 0, pexPeers = 0, readyPeers = 0; std::vector<lt::peer_info> peers; handle.get_peer_info(peers);
		for (auto const& peer : peers) { if (peer.flags & lt::peer_info::rc4_encrypted) ++rc4; if (peer.flags & lt::peer_info::plaintext_encrypted) ++negotiated; if (peer.flags & lt::peer_info::utp_socket) ++utpPeers; else ++tcpPeers; if (peer.source & lt::peer_info::dht) ++dhtPeers; if (peer.source & lt::peer_info::pex) ++pexPeers; }
		for (auto const& peer : peers) if (!(peer.flags & (lt::peer_info::handshake | lt::peer_info::connecting))) ++readyPeers;
		publish(@{@"port":@(session.listen_port()), @"complete":@(status.has_metadata && status.is_finished), @"seeding":@(status.is_seeding), @"rc4":@(rc4), @"negotiated":@(negotiated), @"utp":@(utpPeers), @"tcp":@(tcpPeers),
			@"downloaded":@(status.total_payload_download), @"uploaded":@(status.total_payload_upload), @"failedBytes":@(status.total_failed_bytes), @"redundantBytes":@(status.total_redundant_bytes), @"done":@(status.total_wanted_done), @"wanted":@(status.total_wanted), @"dhtPeers":@(dhtPeers), @"pexPeers":@(pexPeers), @"dhtAnnounces":@(dhtAnnounces), @"readyPeers":@(readyPeers), @"peerErrors":peerErrors}, job[@"status"]);
		if ([job[@"benchmark"] boolValue] && status.is_finished) { stopping = true; break; }
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
