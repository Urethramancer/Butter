#import "ButterEngine.h"
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/bencode.hpp>
#include "EngineTestSupport.h"
namespace lt = libtorrent;

static void record(ButterEngine *engine, NSString *root, NSString *seed, NSString *name, std::vector<char> const& metadata, NSMutableArray *records) {
	NSString *file = [root stringByAppendingPathComponent:[name stringByAppendingString:@".torrent"]];
	require([[NSData dataWithBytes:metadata.data() length:metadata.size()] writeToFile:file atomically:YES], "Cannot write reference torrent");
	NSDictionary *inspection = decode(call(engine, @"inspect", @{@"source":file}));
	call(engine, @"add", @{@"id":name, @"source":file, @"destination":seed});
	NSDictionary *magnet = decode(call(engine, @"magnet", @{@"id":name}));
	[records addObject:@{@"file":file.lastPathComponent, @"inspection":inspection, @"magnet":magnet[@"magnet"]}];
	call(engine, @"remove", @{@"id":name});
}

// Optional reference tool. Writes deterministic metadata plus the bridge's actual
// inspection/magnet responses for consumption by the native Swift harness.
int main(int argc, char **argv) { @autoreleasepool { try {
	require(argc == 2, "Expected a disposable fixture directory");
	NSString *root = [NSString stringWithUTF8String:argv[1]];
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString *seed = [root stringByAppendingPathComponent:@"seed"];
	require([fm createDirectoryAtPath:[seed stringByAppendingPathComponent:@"Bundle/nested"] withIntermediateDirectories:YES attributes:nil error:nil], "Cannot create reference fixture");
	NSMutableData *bytes = [NSMutableData dataWithLength:32771];
	for (NSUInteger i = 0; i < bytes.length; ++i) ((unsigned char *)bytes.mutableBytes)[i] = (i * 71 + i / 97) % 251;
	for (NSString *name in @[@"Å + &!().bin", @"Bundle/a.bin", @"Bundle/nested/b.bin"])
		require([bytes writeToFile:[seed stringByAppendingPathComponent:name] atomically:YES], "Cannot write fixture bytes");
	require([[NSData data] writeToFile:[seed stringByAppendingPathComponent:@"Bundle/empty"] atomically:YES], "Cannot write empty fixture");
	ButterEngine *engine = [[ButterEngine alloc] initWithStorage:[root stringByAppendingPathComponent:@"engine"]];
	NSMutableArray *records = [NSMutableArray array];
	for (bool multi : {false, true}) for (int version : {1, 2, 3}) {
		NSString *name = [NSString stringWithFormat:@"%@-%d", multi ? @"multi" : @"single", version];
		NSString *source = [seed stringByAppendingPathComponent:multi ? @"Bundle" : @"Å + &!().bin"];
		auto flags = version == 1 ? lt::create_torrent::v1_only : version == 2 ? lt::create_torrent::v2_only : lt::create_flags_t{};
		lt::create_torrent creator(lt::list_files(source.UTF8String), 16384, flags);
		creator.set_priv(multi);
		creator.add_tracker("http://127.0.0.1:1/announce?x=1&y=2", 0);
		creator.add_tracker("udp://127.0.0.1:2/announce", 1);
		lt::error_code error; lt::set_piece_hashes(creator, seed.UTF8String, error);
		require(!error, "Cannot hash reference fixture");
		std::vector<char> metadata; lt::bencode(std::back_inserter(metadata), creator.generate());
		record(engine, root, seed, name, metadata, records);
	}
	std::vector<std::string> names = {"../a/b\\c.bin", "invisible\xe2\x80\xae.bin", std::string(300, 'x') + ".txt", "\xff\xe2\x82", "\xfc\x80\x80\x80\x80\x80", "\x01\x7f\xc2\x80.bin"};
	int index = 0;
	for (auto const& raw : names) {
		lt::entry torrent;
		auto& info = torrent["info"];
		info["name"] = raw; info["length"] = 1; info["piece length"] = 16384;
		info["pieces"] = std::string(20, '\x01');
		std::vector<char> bytes; lt::bencode(std::back_inserter(bytes), torrent);
		record(engine, root, seed, [NSString stringWithFormat:@"path-%d", index++], bytes, records);
	}
	call(engine, @"shutdown", @{});
	NSData *manifest = [NSJSONSerialization dataWithJSONObject:records options:NSJSONWritingPrettyPrinted error:nil];
	require([manifest writeToFile:[root stringByAppendingPathComponent:@"reference.json"] atomically:YES], "Cannot write comparison manifest");
	return 0;
} catch (std::exception const& error) { fprintf(stderr, "FAIL: %s\n", error.what()); return 1; } } }
