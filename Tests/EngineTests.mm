#import "ButterEngine.h"
#import <Foundation/Foundation.h>
#include <thread>
#include <chrono>
#include <stdexcept>
static NSDictionary *decode(NSData *data) { return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]; }
static NSData *call(ButterEngine *engine, NSString *command, NSDictionary *payload) {
	__block NSData *result; __block NSString *failure;
	auto done = dispatch_semaphore_create(0);
	[engine perform:command payload:[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil] completion:^(NSData *data, NSString *error) { result = data; failure = error; dispatch_semaphore_signal(done); }];
	if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC))) throw std::runtime_error("Command timed out");
	if (failure) throw std::runtime_error(failure.UTF8String); return result;
}
static NSDictionary *snapshot(ButterEngine *engine) {
	__block NSData *result; __block NSString *failure; auto done = dispatch_semaphore_create(0);
	[engine snapshot:^(NSData *data, NSString *error) { result = data; failure = error; dispatch_semaphore_signal(done); }];
	if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC))) throw std::runtime_error("Snapshot timed out");
	if (failure) throw std::runtime_error(failure.UTF8String); return decode(result);
}
static void require(bool condition, char const *message) { if (!condition) throw std::runtime_error(message); }
int main() { @autoreleasepool { try {
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
		NSDictionary *created = decode(call(a, @"create", @{@"id":@"fixture", @"source":source, @"trackers":@[], @"private":@NO}));
		NSString *torrent = created[@"source"];
		NSDictionary *add = @{@"id":@"fixture", @"source":torrent, @"destination":seed};
		call(a, @"add", add);
		NSDictionary *duplicate = decode(call(a, @"add", @{@"id":@"other", @"source":torrent, @"destination":seed})); require([duplicate[@"duplicate"] boolValue], "Duplicate detection");
		NSString *download = [root stringByAppendingPathComponent:@"download"];
		call(b, @"add", @{@"id":@"fixture", @"source":torrent, @"destination":download});
		call(a, @"run", @{@"id":@"fixture", @"running":@YES}); call(b, @"run", @{@"id":@"fixture", @"running":@YES});
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
		__block bool pumping = true;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ while (pumping) { snapshot(b); std::this_thread::sleep_for(std::chrono::milliseconds(20)); } });
		NSData *exported = call(b, @"export", @{@"id":@"fixture"}); pumping = false;
		NSString *exportPath = [root stringByAppendingPathComponent:@"export.torrent"]; [exported writeToFile:exportPath atomically:YES];
		NSDictionary *preview = decode(call(b, @"inspect", @{@"source":exportPath})); require([preview[@"hashes"] isEqual:hashes], "Export changed info hashes after rename");
		call(b, @"shutdown", @{});
		ButterEngine *c = [[ButterEngine alloc] initWithStorage:[root stringByAppendingPathComponent:@"b"]]; call(c, @"settings", settings);
		call(c, @"add", @{@"id":@"fixture", @"source":torrent, @"destination":download, @"restore":@YES});
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
		call(c, @"shutdown", @{}); call(a, @"shutdown", @{});

		printf("PASS: hybrid creation, duplicate detection, verified µTP-only transfer, rename and hash-preserving export, resume recovery, collision rejection, confirmed move, data-retaining removal and TCP magnet metadata\n");
	} @finally { [fm removeItemAtPath:root error:nil]; }
	return 0;
} catch (std::exception const& e) { fprintf(stderr, "FAIL: %s\n", e.what()); return 1; } } }
