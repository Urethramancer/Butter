#import "ButterEngine.h"
#include "EngineTestSupport.h"

int main(int argc, char **argv) { @autoreleasepool { try {
	require(argc == 2, "Expected a disposable fixture directory");
	NSString *root = [NSString stringWithUTF8String:argv[1]];
	NSArray *fixtures = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"creation.json"]] options:0 error:nil];
	require(fixtures.count == 8, "Missing native creation fixtures");
	int count = 0;
	for (NSDictionary *fixture in fixtures) {
		NSString *key = [NSString stringWithFormat:@"creation-%d", count++];
		ButterEngine *seed = [[ButterEngine alloc] initWithStorage:[root stringByAppendingPathComponent:[key stringByAppendingString:@"-seed-engine"]]];
		ButterEngine *download = [[ButterEngine alloc] initWithStorage:[root stringByAppendingPathComponent:[key stringByAppendingString:@"-download-engine"]]];
		NSDictionary *settings = @{@"port":@0, @"tcp":@YES, @"utp":@NO, @"dht":@NO, @"pex":@NO, @"lsd":@NO, @"mapping":@NO, @"peers":@20, @"torrentPeers":@10};
		call(seed, @"settings", settings); call(download, @"settings", settings);
		NSDictionary *preview = decode(call(seed, @"inspect", @{@"source":fixture[@"torrent"]}));
		require([preview[@"hashes"] count] == (count <= 4 ? 2 : 1), "Native creation has the wrong hash variants");
		call(seed, @"add", @{@"id":key, @"source":fixture[@"torrent"], @"destination":fixture[@"destination"]});
		call(download, @"add", @{@"id":key, @"source":fixture[@"torrent"], @"destination":fixture[@"output"]});
		call(seed, @"run", @{@"id":key, @"running":@YES}); call(download, @"run", @{@"id":key, @"running":@YES});
		bool complete = false;
		for (int attempt = 0; attempt < 1200; ++attempt) {
			NSDictionary *row = [snapshot(download)[@"transfers"] firstObject];
			if ([row[@"complete"] boolValue] && [row[@"wanted"] longLongValue] > 0 && [row[@"done"] isEqual:row[@"wanted"]]) { complete = true; break; }
			NSDictionary *bound = snapshot(seed);
			if (attempt % 20 == 0 && [bound[@"port"] intValue]) call(download, @"connect", @{@"id":key, @"address":@"127.0.0.1", @"port":bound[@"port"]});
			std::this_thread::sleep_for(std::chrono::milliseconds(25));
		}
		require(complete, "Reference could not transfer native hybrid torrent");
		call(download, @"shutdown", @{}); call(seed, @"shutdown", @{});
		for (NSDictionary *file in preview[@"files"]) {
			if ([file[@"pad"] boolValue]) continue;
			NSData *expected = [NSData dataWithContentsOfFile:[fixture[@"destination"] stringByAppendingPathComponent:file[@"path"]]];
			NSData *actual = [NSData dataWithContentsOfFile:[fixture[@"output"] stringByAppendingPathComponent:file[@"path"]]];
			require(expected && [expected isEqual:actual], "Reference transfer bytes differ from creation source");
		}
	}
	printf("PASS: eight native single/multifile hybrid and v2-only torrents transfer through libtorrent with byte verification\n");
	return 0;
} catch (std::exception const& error) { fprintf(stderr, "FAIL: %s\n", error.what()); return 1; } } }
