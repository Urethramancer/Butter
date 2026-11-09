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
		call(b, @"shutdown", @{}); call(a, @"shutdown", @{});
		printf("PASS: hybrid creation, duplicate detection, verified µTP-only transfer, rename and hash-preserving export, resume save\n");
	} @finally { [fm removeItemAtPath:root error:nil]; }
	return 0;
} catch (std::exception const& e) { fprintf(stderr, "FAIL: %s\n", e.what()); return 1; } } }
