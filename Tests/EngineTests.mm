#import "ButterEngine.h"
#import <Foundation/Foundation.h>
#include <thread>
#include <chrono>
#include <stdexcept>
#include <atomic>
#include <memory>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/bencode.hpp>
namespace lt = libtorrent;
#include "EngineTestSupport.h"
#include "EngineRegressionCases.h"
int main() { @autoreleasepool { try {
	NSString *selectedCase = NSProcessInfo.processInfo.environment[@"BUTTER_TEST_CASE"];
	if (selectedCase && ![@[@"engine-validation", @"concurrent-exports", @"filesystem-failures", @"metadata-variants", @"transfer-integration"] containsObject:selectedCase]) throw std::runtime_error("Unknown engine test case");
	NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	NSFileManager *fm = NSFileManager.defaultManager; [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
	@try {
		NSString *seed = [root stringByAppendingPathComponent:@"seed"]; [fm createDirectoryAtPath:seed withIntermediateDirectories:YES attributes:nil error:nil];
		NSMutableData *fixture = [NSMutableData dataWithLength:1024 * 1024 * 8]; for (NSUInteger i = 0; i < fixture.length; ++i) ((unsigned char *)fixture.mutableBytes)[i] = (i * 71 + i / 97) % 251;
		NSString *source = [seed stringByAppendingPathComponent:@"fixture.bin"]; [fixture writeToFile:source atomically:YES];
		ButterEngine *a = [[ButterEngine alloc] initWithStorage:[root stringByAppendingPathComponent:@"a"]];
		ButterEngine *b = [[ButterEngine alloc] initWithStorage:[root stringByAppendingPathComponent:@"b"]];
		NSDictionary *settings = @{@"port":@0, @"utp":@YES, @"tcp":@NO, @"mapping":@NO, @"dht":@NO, @"lsd":@NO, @"pex":@NO, @"peers":@20, @"torrentPeers":@10};
		call(a, @"settings", settings); call(b, @"settings", settings);
		auto cancelled = dispatch_semaphore_create(0); __block NSString *cancelError = nil;
		NSData *cancelInput = [NSJSONSerialization dataWithJSONObject:@{@"id":@"cancelled", @"source":source, @"trackers":@[], @"private":@NO} options:0 error:nil];
		[a perform:@"create" payload:cancelInput completion:^(NSData *, NSString *error) { cancelError = error; dispatch_semaphore_signal(cancelled); }]; [a cancelCreation];
		require(dispatch_semaphore_wait(cancelled, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0 && cancelError != nil, "Creation cancellation was ignored");
		require(![fm fileExistsAtPath:[[root stringByAppendingPathComponent:@"a"] stringByAppendingPathComponent:@"cancelled.torrent"]], "Cancelled creation wrote metadata");
		NSDictionary *created = decode(call(a, @"create", @{@"id":@"fixture", @"source":source, @"trackers":@[], @"private":@NO}));
		NSString *torrent = created[@"source"];
		ButterEngine *regression = [[ButterEngine alloc] initWithStorage:[root stringByAppendingPathComponent:@"regression"]];
		call(regression, @"settings", settings);
		call(regression, @"add", @{@"id":@"fixture", @"source":torrent, @"destination":seed});
		if (!selectedCase || [selectedCase isEqual:@"engine-validation"]) validationCases(regression, torrent, seed);
		call(regression, @"remove", @{@"id":@"fixture"});
		if (!selectedCase || [selectedCase isEqual:@"concurrent-exports"]) exportCases(regression, torrent, seed);
		if (!selectedCase || [selectedCase isEqual:@"filesystem-failures"]) filesystemCases(regression, torrent, source, seed, [root stringByAppendingPathComponent:@"regression"]);
		call(regression, @"shutdown", @{});
		if (!selectedCase || [selectedCase isEqual:@"metadata-variants"]) metadataVariantCases(root, source, seed, settings);
		if (selectedCase && ![selectedCase isEqual:@"transfer-integration"]) { call(a, @"shutdown", @{}); call(b, @"shutdown", @{}); return 0; }

		NSDictionary *add = @{@"id":@"fixture", @"source":torrent, @"destination":seed};
		call(a, @"add", add);
		NSDictionary *duplicate = decode(call(a, @"add", @{@"id":@"other", @"source":torrent, @"destination":seed})); require([duplicate[@"duplicate"] boolValue], "Duplicate detection");
		NSString *download = [root stringByAppendingPathComponent:@"download"];
		call(b, @"add", @{@"id":@"fixture", @"source":torrent, @"destination":download});
		call(a, @"run", @{@"id":@"fixture", @"running":@YES}); call(b, @"run", @{@"id":@"fixture", @"running":@YES, @"downloadLimit":@(2 * 1024 * 1024)});
		bool complete = false, utp = false;
		for (int i = 0; i < 1200; ++i) {
			auto sa = snapshot(a); auto sb = snapshot(b);
			NSDictionary *t = [sb[@"transfers"] firstObject];
			for (NSDictionary *peer in t[@"peers"]) if ([peer[@"utp"] boolValue]) utp = true;
			if ([t[@"complete"] boolValue]) { complete = true; break; }
			if (i % 10 == 0 && [sa[@"port"] intValue] > 0) call(b, @"connect", @{@"id":@"fixture", @"address":@"127.0.0.1", @"port":sa[@"port"]});
			std::this_thread::sleep_for(std::chrono::milliseconds(25));
		}
		require(complete, "µTP-only transfer did not complete"); require(utp, "No µTP peer observed");
		require([[NSData dataWithContentsOfFile:[download stringByAppendingPathComponent:@"fixture.bin"]] isEqual:fixture], "Downloaded bytes differ");
		NSArray *hashes = [snapshot(b)[@"transfers"] firstObject][@"hashes"];
		call(b, @"rename", @{@"id":@"fixture", @"changes":@[@{@"index":@0, @"path":@"renamed.bin"}]});
		for (int i = 0; i < 100; ++i) { snapshot(b); if ([fm fileExistsAtPath:[download stringByAppendingPathComponent:@"renamed.bin"]]) break; std::this_thread::sleep_for(std::chrono::milliseconds(50)); }
		// Export waits for an asynchronous save-resume alert. Pump snapshots from another thread.
		auto pumping = std::make_shared<std::atomic<bool>>(true); auto pumpDone = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ while (*pumping) { snapshot(b); std::this_thread::sleep_for(std::chrono::milliseconds(20)); } dispatch_semaphore_signal(pumpDone); });
		NSData *exported = call(b, @"export", @{@"id":@"fixture"}); *pumping = false; dispatch_semaphore_wait(pumpDone, DISPATCH_TIME_FOREVER);
		NSString *exportPath = [root stringByAppendingPathComponent:@"export.torrent"]; [exported writeToFile:exportPath atomically:YES];
		NSDictionary *preview = decode(call(b, @"inspect", @{@"source":exportPath})); require([preview[@"hashes"] isEqual:hashes], "Export changed info hashes after rename");
		call(b, @"shutdown", @{});
		// Simulate a crash after a disk rename but before its receipt/resume update.
		NSString *journalPath = [[root stringByAppendingPathComponent:@"b"] stringByAppendingPathComponent:@"fixture.paths.json"];
		NSDictionary *journal = @{@"destination":download, @"paths":@[@{@"index":@0, @"original":@"fixture.bin", @"path":@"fixture.bin"}], @"pending":@[@{@"index":@0, @"path":@"renamed.bin"}]};
		[[NSJSONSerialization dataWithJSONObject:journal options:0 error:nil] writeToFile:journalPath atomically:YES];
		ButterEngine *c = [[ButterEngine alloc] initWithStorage:[root stringByAppendingPathComponent:@"b"]]; call(c, @"settings", settings);
		call(c, @"add", @{@"id":@"fixture", @"source":torrent, @"destination":download, @"restore":@YES});
		require([[[snapshot(c)[@"transfers"] firstObject][@"error"] description] length] > 0, "Interrupted rename must require review before resuming");
		call(c, @"retry", @{@"id":@"fixture"});
		call(c, @"run", @{@"id":@"fixture", @"running":@YES});
		bool recovered = false;
		for (int i = 0; i < 100; ++i) {
			NSDictionary *row = [snapshot(c)[@"transfers"] firstObject];
			NSDictionary *file = [row[@"files"] firstObject];
			if ([row[@"complete"] boolValue]) { require([file[@"path"] isEqual:@"renamed.bin"], "Resume lost local rename"); require([file[@"original"] isEqual:@"fixture.bin"], "Resume lost original name"); recovered = true; break; }
			std::this_thread::sleep_for(std::chrono::milliseconds(30));
		}
		require(recovered, "Resume recovery did not retain verified data");
		NSString *collision = [download stringByAppendingPathComponent:@"collision.bin"]; [fixture writeToFile:collision atomically:YES];
		bool rejected = false;
		try { call(c, @"rename", @{@"id":@"fixture", @"changes":@[@{@"index":@0, @"path":@"collision.bin"}]}); } catch (std::exception const&) { rejected = true; }
		require(rejected, "Rename collision was not rejected");
		NSString *final = [root stringByAppendingPathComponent:@"final"];
		call(c, @"move", @{@"id":@"fixture", @"destination":final});
		bool moved = false;
		for (int i = 0; i < 100; ++i) { NSDictionary *shot = snapshot(c); for (NSDictionary *event in shot[@"events"]) if ([event[@"kind"] isEqual:@"moved"]) moved = true; if (moved) break; std::this_thread::sleep_for(std::chrono::milliseconds(30)); }
		require(moved && [fm fileExistsAtPath:[final stringByAppendingPathComponent:@"renamed.bin"]], "Confirmed completion move failed");
		require([fm fileExistsAtPath:collision], "Move affected an unrelated neighbour");
		call(c, @"remove", @{@"id":@"fixture", @"trash":@NO});
		require([fm fileExistsAtPath:[final stringByAppendingPathComponent:@"renamed.bin"]], "Ordinary removal deleted downloaded data");
		// Resolve metadata over loopback, this time with TCP enabled and µTP disabled.
		NSDictionary *tcp = @{@"port":@0, @"utp":@NO, @"tcp":@YES, @"mapping":@NO, @"dht":@NO, @"lsd":@NO, @"pex":@NO, @"peers":@20, @"torrentPeers":@10};
		call(a, @"settings", tcp); call(c, @"settings", tcp);
		NSString *magnet = decode(call(a, @"magnet", @{@"id":@"fixture"}))[@"magnet"];
		NSString *magnetPath = [root stringByAppendingPathComponent:@"magnet"];
		call(c, @"add", @{@"id":@"magnet", @"source":magnet, @"destination":magnetPath}); call(c, @"run", @{@"id":@"magnet", @"running":@YES});
		bool metadata = false;
		for (int i = 0; i < 1200; ++i) {
			NSDictionary *sa = snapshot(a), *sc = snapshot(c); NSDictionary *row = [sc[@"transfers"] firstObject];
			if ([row[@"metadata"] boolValue]) metadata = true;
			if ([row[@"complete"] boolValue]) break;
			if (i % 20 == 0 && [sa[@"port"] intValue]) call(c, @"connect", @{@"id":@"magnet", @"address":@"127.0.0.1", @"port":sa[@"port"]});
			std::this_thread::sleep_for(std::chrono::milliseconds(25));
		}
		require(metadata, "Magnet metadata did not resolve over TCP");
		require([[NSData dataWithContentsOfFile:[magnetPath stringByAppendingPathComponent:@"fixture.bin"]] isEqual:fixture], "TCP magnet transfer failed");
		call(c, @"shutdown", @{});
		NSMutableData *corrupt = [fixture mutableCopy]; ((unsigned char *)corrupt.mutableBytes)[100] ^= 0xff;
		[corrupt writeToFile:[magnetPath stringByAppendingPathComponent:@"fixture.bin"] atomically:NO];
		call(c, @"recheck", @{@"id":@"magnet"}); call(c, @"run", @{@"id":@"magnet", @"running":@YES});
		bool detected = false, repaired = false;
		for (int i = 0; i < 1200; ++i) {
			NSDictionary *sa = snapshot(a), *row = [snapshot(c)[@"transfers"] firstObject];
			if (![row[@"complete"] boolValue]) detected = true;
			if (detected && [row[@"complete"] boolValue]) { repaired = true; break; }
			if (i % 20 == 0) call(c, @"connect", @{@"id":@"magnet", @"address":@"127.0.0.1", @"port":sa[@"port"]});
			std::this_thread::sleep_for(std::chrono::milliseconds(25));
		}
		require(detected && repaired, "Corruption was not detected and retried");
		require([[NSData dataWithContentsOfFile:[magnetPath stringByAppendingPathComponent:@"fixture.bin"]] isEqual:fixture], "Corruption retry did not restore bytes");
		NSString *multi = [seed stringByAppendingPathComponent:@"nested"], *inner = [multi stringByAppendingPathComponent:@"inner"];
		[fm createDirectoryAtPath:inner withIntermediateDirectories:YES attributes:nil error:nil];
		[fixture writeToFile:[inner stringByAppendingPathComponent:@"wanted.bin"] atomically:YES];
		[[NSData dataWithBytes:"skip" length:4] writeToFile:[inner stringByAppendingPathComponent:@"skipped.bin"] atomically:YES];
		NSString *multiTorrent = decode(call(a, @"create", @{@"id":@"multi", @"source":multi, @"trackers":@[], @"private":@NO}))[@"source"];
		NSDictionary *multiPreview = decode(call(a, @"inspect", @{@"source":multiTorrent})); NSMutableArray *selected = [NSMutableArray array]; int wantedIndex = -1;
		for (NSDictionary *file in multiPreview[@"files"]) { bool wanted = [file[@"path"] hasSuffix:@"wanted.bin"]; [selected addObject:@(wanted)]; if (wanted) wantedIndex = [file[@"index"] intValue]; }
		call(a, @"add", @{@"id":@"multi", @"source":multiTorrent, @"destination":seed}); call(a, @"run", @{@"id":@"multi", @"running":@YES});
		NSString *selectivePath = [root stringByAppendingPathComponent:@"selective"];
		call(c, @"add", @{@"id":@"multi", @"source":multiTorrent, @"destination":selectivePath, @"selected":selected}); call(c, @"run", @{@"id":@"multi", @"running":@YES});
		call(c, @"blocklist", @{@"ranges":@[@{@"first":@"127.0.0.1", @"last":@"127.0.0.1"}]});
		NSDictionary *sa = snapshot(a); call(c, @"connect", @{@"id":@"multi", @"address":@"127.0.0.1", @"port":sa[@"port"]});
		std::this_thread::sleep_for(std::chrono::milliseconds(200));
		for (NSDictionary *row in snapshot(c)[@"transfers"]) if ([row[@"id"] isEqual:@"multi"]) require([row[@"peers"] count] == 0, "Blocklisted peer connected");
		call(c, @"blocklist", @{@"ranges":@[]});
		bool selectiveComplete = false;
		for (int i = 0; i < 1200; ++i) {
			sa = snapshot(a);
			for (NSDictionary *row in snapshot(c)[@"transfers"]) if ([row[@"id"] isEqual:@"multi"] && [row[@"complete"] boolValue]) selectiveComplete = true;
			if (selectiveComplete) break;
			if (i % 20 == 0) call(c, @"connect", @{@"id":@"multi", @"address":@"127.0.0.1", @"port":sa[@"port"]});
			std::this_thread::sleep_for(std::chrono::milliseconds(25));
		}
		require(selectiveComplete, "Selective transfer did not finish selected files");
		require(![fm fileExistsAtPath:[selectivePath stringByAppendingPathComponent:@"nested/inner/skipped.bin"]], "Unselected file was downloaded");
		NSArray *multiHashes = multiPreview[@"hashes"];
		call(c, @"rename", @{@"id":@"multi", @"changes":@[@{@"index":@(wantedIndex), @"path":@"renamed/inside/wanted.bin"}]});
		for (int i = 0; i < 100; ++i) { snapshot(c); if ([fm fileExistsAtPath:[selectivePath stringByAppendingPathComponent:@"renamed/inside/wanted.bin"]]) break; std::this_thread::sleep_for(std::chrono::milliseconds(30)); }
		for (NSDictionary *row in snapshot(c)[@"transfers"]) if ([row[@"id"] isEqual:@"multi"]) { require([row[@"hashes"] isEqual:multiHashes], "Nested rename changed identity"); for (NSDictionary *file in row[@"files"]) if ([file[@"index"] intValue] == wantedIndex) { require([file[@"path"] isEqual:@"renamed/inside/wanted.bin"], "Nested rename missing current path"); require([file[@"original"] isEqual:@"nested/inner/wanted.bin"], "Nested rename lost original path"); } }
		NSString *conflict = [root stringByAppendingPathComponent:@"conflict"], *conflictParent = [conflict stringByAppendingPathComponent:@"renamed/inside"];
		[fm createDirectoryAtPath:conflictParent withIntermediateDirectories:YES attributes:nil error:nil];
		NSData *neighbour = [NSData dataWithBytes:"neighbour" length:9]; NSString *collisionPath = [conflictParent stringByAppendingPathComponent:@"wanted.bin"];
		[neighbour writeToFile:collisionPath atomically:YES];
		bool failedMove = false;
		try { call(c, @"move", @{@"id":@"multi", @"destination":conflict}); } catch (std::exception const&) { failedMove = true; }
		for (int i = 0; !failedMove && i < 100; ++i) { for (NSDictionary *event in snapshot(c)[@"events"]) if ([event[@"kind"] isEqual:@"moveFailed"]) failedMove = true; if (failedMove) break; std::this_thread::sleep_for(std::chrono::milliseconds(30)); }
		require(failedMove, "Move collision did not produce a visible failure"); require([[NSData dataWithContentsOfFile:collisionPath] isEqual:neighbour], "Failed move damaged neighbouring file");
		NSString *unrelated = [selectivePath stringByAppendingPathComponent:@"unrelated.bin"]; [neighbour writeToFile:unrelated atomically:YES];
		NSDictionary *removed = decode(call(c, @"remove", @{@"id":@"multi", @"trash":@YES}));
		require([removed[@"trashed"] count] == 1, "Trash must include only existing managed files");
		require([fm fileExistsAtPath:unrelated] && [[NSData dataWithContentsOfFile:unrelated] isEqual:neighbour], "Trash removal affected unrelated contents");
		for (NSString *receipt in removed[@"trashed"]) { NSError *error = nil; require([fm removeItemAtPath:receipt error:&error], "Could not clean up test-only Trash receipt"); }
		ButterEngine *d = [[ButterEngine alloc] initWithStorage:[root stringByAppendingPathComponent:@"d"]]; call(d, @"settings", tcp);
		NSString *v1Magnet = [@"magnet:?xt=urn:btih:" stringByAppendingString:hashes[0]], *v2Magnet = [@"magnet:?xt=urn:btmh:1220" stringByAppendingString:hashes[1]];
		call(d, @"add", @{@"id":@"first", @"source":v1Magnet, @"destination":[root stringByAppendingPathComponent:@"first"]});
		call(d, @"add", @{@"id":@"second", @"source":v2Magnet, @"destination":[root stringByAppendingPathComponent:@"second"]});
		call(d, @"run", @{@"id":@"first", @"running":@YES}); call(d, @"run", @{@"id":@"second", @"running":@YES});
		bool conflictResolved = false;
		for (int i = 0; i < 1200; ++i) {
			NSDictionary *sa = snapshot(a), *sd = snapshot(d);
			for (NSDictionary *event in sd[@"events"]) if ([event[@"kind"] isEqual:@"duplicate"]) { require([event[@"existingID"] isEqual:@"first"], "Resolved duplicate did not keep addition order"); conflictResolved = true; }
			if (conflictResolved) { require([sd[@"transfers"] count] == 1, "Resolved duplicate retained both entries"); break; }
			if (i % 20 == 0) { call(d, @"connect", @{@"id":@"first", @"address":@"127.0.0.1", @"port":sa[@"port"]}); call(d, @"connect", @{@"id":@"second", @"address":@"127.0.0.1", @"port":sa[@"port"]}); }
			std::this_thread::sleep_for(std::chrono::milliseconds(25));
		}
		require(conflictResolved, "Separately resolved v1/v2 magnets were not deduplicated");
		NSMutableDictionary *limited = [tcp mutableCopy]; limited[@"peers"] = @1; limited[@"torrentPeers"] = @80; limited[@"allowSameIP"] = @YES;
		call(d, @"settings", limited); call(d, @"run", @{@"id":@"first", @"running":@YES});
		NSDictionary *aPort = snapshot(a), *cPort = snapshot(c);
		call(d, @"connect", @{@"id":@"first", @"address":@"127.0.0.1", @"port":aPort[@"port"]}); call(d, @"connect", @{@"id":@"first", @"address":@"127.0.0.1", @"port":cPort[@"port"]});
		bool connected = false;
		for (int i = 0; i < 100; ++i) { NSDictionary *row = [snapshot(d)[@"transfers"] firstObject]; NSUInteger count = [row[@"peers"] count]; require(count <= 1, "Global peer limit was exceeded"); connected |= count > 0; if ([row[@"complete"] boolValue]) break; std::this_thread::sleep_for(std::chrono::milliseconds(10)); }
		require(connected, "Peer-limit test did not connect to a seed");
		int occupied = socket(AF_INET, SOCK_STREAM, 0); require(occupied >= 0, "Cannot allocate occupied-port fixture");
		sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		require(bind(occupied, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0 && listen(occupied, 1) == 0, "Cannot bind occupied-port fixture");
		socklen_t length = sizeof(address); getsockname(occupied, reinterpret_cast<sockaddr *>(&address), &length);
		NSMutableDictionary *busy = [tcp mutableCopy]; busy[@"port"] = @(ntohs(address.sin_port)); call(d, @"settings", busy);
		bool bindingFailed = false;
		for (int i = 0; i < 100; ++i) { if ([snapshot(d)[@"networkError"] length]) { bindingFailed = true; break; } std::this_thread::sleep_for(std::chrono::milliseconds(50)); }
		if (!bindingFailed) fprintf(stderr, "Occupied port %d; reported binding port %d\n", ntohs(address.sin_port), [snapshot(d)[@"port"] intValue]);
		close(occupied); require(bindingFailed, "Occupied port did not produce a binding failure");
		NSDictionary *random = decode(call(d, @"settings", tcp)); bool rebound = false;
		for (int i = 0; i < 100; ++i) { NSDictionary *shot = snapshot(d); if ([shot[@"port"] isEqual:random[@"port"]] && ![shot[@"networkError"] length] && [shot[@"udp"] boolValue]) { rebound = true; break; } std::this_thread::sleep_for(std::chrono::milliseconds(10)); }
		require(rebound, "Random port did not recover from occupied-port failure");
		call(d, @"shutdown", @{});
		call(c, @"shutdown", @{}); call(a, @"shutdown", @{});

		printf("PASS: hybrid creation, duplicate detection, verified µTP-only transfer, rename and hash-preserving export, resume recovery, collision rejection, confirmed move, data-retaining removal, TCP magnet metadata, corruption/retry, selective files, blocklist enforcement, nested rename identity, move failure, Trash isolation, resolved-magnet duplicates, hard peer limits, occupied-port recovery and cancellation\n");
	} @finally { [fm removeItemAtPath:root error:nil]; }
	return 0;
} catch (std::exception const& e) { fprintf(stderr, "FAIL: %s\n", e.what()); return 1; } } }
