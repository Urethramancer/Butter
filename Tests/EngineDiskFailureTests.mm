#include "EngineTestSupport.h"

static bool diskFull(NSError *error) {
	return ([error.domain isEqual:NSPOSIXErrorDomain] && error.code == ENOSPC)
		|| ([error.domain isEqual:NSCocoaErrorDomain] && error.code == NSFileWriteOutOfSpaceError)
		|| ([error.userInfo[NSUnderlyingErrorKey] isKindOfClass:NSError.class] && diskFull(error.userInfo[NSUnderlyingErrorKey]));
}
static void failCommand(ButterEngine *engine, NSString *command, NSDictionary *payload) {
	bool failed = false;
	try { call(engine, command, payload); } catch (std::exception const&) { failed = true; }
	if (!failed) throw std::runtime_error(std::string("Filesystem failure was not surfaced for ") + command.UTF8String);
}
static NSFileHandle *fill(NSString *path) {
	NSFileManager *fm = NSFileManager.defaultManager;
	require([fm createFileAtPath:path contents:nil attributes:nil], "Cannot create disk filler");
	NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path]; require(handle != nil, "Cannot open disk filler");
	for (NSUInteger size : {1024 * 1024, 4096}) {
		NSData *bytes = [NSMutableData dataWithLength:size]; bool full = false;
		for (int attempt = 0; attempt < 4096; ++attempt) {
			NSError *error = nil;
			if (![handle writeData:bytes error:&error]) { require(diskFull(error), "Filler failed for a reason other than ENOSPC"); full = true; break; }
		}
		require(full, "Disposable fixture volume was not filled");
	}
	return handle;
}
int main(int argc, char **argv) { @autoreleasepool { try {
	require(argc >= 3, "Expected disposable volume and source fixture root");
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString *volume = @(argv[1]), *root = @(argv[2]);
	require([fm fileExistsAtPath:[volume stringByAppendingPathComponent:@".butter-disk-test"]], "Missing disposable-volume marker");
	NSString *storage = [volume stringByAppendingPathComponent:@"Engine"], *source = [root stringByAppendingPathComponent:@"source"];
	NSString *torrent = [[root stringByAppendingPathComponent:@"builder"] stringByAppendingPathComponent:@"fixture.torrent"];
	NSString *importTorrent = [[root stringByAppendingPathComponent:@"builder"] stringByAppendingPathComponent:@"import.torrent"];
	ButterEngine *engine = [[ButterEngine alloc] initWithStorage:storage];
	if (argc == 4 && std::string(argv[3]) == "--cleanup") {
		NSString *journal = [storage stringByAppendingPathComponent:@"fixture.paths.json"], *backup = [storage stringByAppendingPathComponent:@"fixture.paths.backup"];
		require([fm moveItemAtPath:journal toPath:backup error:nil] && [fm createDirectoryAtPath:journal withIntermediateDirectories:NO attributes:nil error:nil], "Cannot inject metadata cleanup failure");
		NSString *neighbour = [journal stringByAppendingPathComponent:@"retained-neighbour"];
		NSData *bytes = [@"retained" dataUsingEncoding:NSUTF8StringEncoding]; require([bytes writeToFile:neighbour atomically:YES], "Cannot create cleanup neighbour");
		failCommand(engine, @"forget", @{@"id":@"fixture"});
		require([[NSData dataWithContentsOfFile:neighbour] isEqual:bytes], "Failed cleanup removed unrelated contents recursively");
		require([fm removeItemAtPath:neighbour error:nil] && [fm removeItemAtPath:journal error:nil] && [fm moveItemAtPath:backup toPath:journal error:nil], "Cannot restore cleanup fixture");
		call(engine, @"forget", @{@"id":@"fixture"});
		require(![fm fileExistsAtPath:journal] && [[NSData dataWithContentsOfFile:[source stringByAppendingPathComponent:@"bundle/a.bin"]] isEqual:[NSMutableData dataWithLength:128 * 1024]], "Cleanup retry lost source data or retained stale metadata");
		printf("PASS: partial metadata cleanup retains unrelated contents and retry completes safely\n"); return 0;
	}
	if (argc == 4 && std::string(argv[3]) == "--read-only") {
		NSMutableDictionary *originals = [NSMutableDictionary dictionary];
		for (NSString *suffix in @[@".torrent", @".resume", @".paths.json"]) {
			NSString *path = [storage stringByAppendingPathComponent:[@"fixture" stringByAppendingString:suffix]];
			NSData *bytes = [NSData dataWithContentsOfFile:path]; require(bytes != nil, "Read-only fixture state missing"); originals[path] = bytes;
		}
		failCommand(engine, @"add", @{@"id":@"fixture", @"source":[storage stringByAppendingPathComponent:@"fixture.torrent"], @"destination":source, @"restore":@YES});
		failCommand(engine, @"add", @{@"id":@"readonly-import", @"source":importTorrent, @"destination":source});
		failCommand(engine, @"forget", @{@"id":@"fixture"});
		require([snapshot(engine)[@"transfers"] count] == 0, "Failed read-only import published a handle");
		for (NSString *path in originals) require([[NSData dataWithContentsOfFile:path] isEqual:originals[path]], "Read-only restore damaged saved engine state");
		printf("PASS: actual read-only imports/restoration fail without publishing handles or changing metadata\n"); return 0;
	}
	NSString *bundle = [source stringByAppendingPathComponent:@"bundle"];
	require([fm createDirectoryAtPath:bundle withIntermediateDirectories:YES attributes:nil error:nil], "Cannot create disk-failure source");
	NSData *original = [NSMutableData dataWithLength:128 * 1024];
	for (NSString *name in @[@"a.bin", @"b.bin"]) require([original writeToFile:[bundle stringByAppendingPathComponent:name] atomically:YES], "Cannot write disk-failure source");
	ButterEngine *builder = [[ButterEngine alloc] initWithStorage:[root stringByAppendingPathComponent:@"builder"]];
	call(builder, @"create", @{@"id":@"fixture", @"source":bundle, @"trackers":@[], @"private":@NO});
	NSString *independent = [source stringByAppendingPathComponent:@"independent.bin"];
	require([original writeToFile:independent atomically:YES], "Cannot write independent import source");
	call(builder, @"create", @{@"id":@"import", @"source":independent, @"trackers":@[], @"private":@NO});
	call(builder, @"shutdown", @{});
	call(engine, @"add", @{@"id":@"fixture", @"source":torrent, @"destination":source});
	call(engine, @"run", @{@"id":@"fixture", @"running":@YES});
	bool verified = false;
	for (int attempt = 0; attempt < 1000; ++attempt) {
		NSDictionary *row = [snapshot(engine)[@"transfers"] firstObject];
		if ([row[@"complete"] boolValue] && [row[@"done"] longLongValue] == 256 * 1024) { verified = true; break; }
		std::this_thread::sleep_for(std::chrono::milliseconds(5));
	}
	require(verified, "Disk-failure source did not verify"); call(engine, @"shutdown", @{});
	require(call(engine, @"export", @{@"id":@"fixture"}).length > 0, "Baseline export failed before disk exhaustion");
	NSMutableDictionary *saved = [NSMutableDictionary dictionary];
	for (NSString *suffix in @[@".torrent", @".resume", @".paths.json"]) {
		NSString *path = [storage stringByAppendingPathComponent:[@"fixture" stringByAppendingString:suffix]];
		NSData *bytes = [NSData dataWithContentsOfFile:path]; require(bytes != nil, "Initial engine state missing"); saved[path] = bytes;
	}
	NSDictionary *preview = decode(call(engine, @"inspect", @{@"source":torrent}));
	NSDictionary *file = nil; for (NSDictionary *entry in preview[@"files"]) if (![entry[@"pad"] boolValue]) { file = entry; break; }
	require(file != nil, "Missing managed file");
	NSString *filler = [volume stringByAppendingPathComponent:@"engine-filler"];
	NSFileHandle *fillerHandle = fill(filler);
	failCommand(engine, @"add", @{@"id":@"full-import", @"source":importTorrent, @"destination":source});
	require([snapshot(engine)[@"transfers"] count] == 1 && ![fm fileExistsAtPath:[storage stringByAppendingPathComponent:@"full-import.torrent"]], "Failed full-disk import published state");
	failCommand(engine, @"rename", @{@"id":@"fixture", @"changes":@[@{@"index":file[@"index"], @"path":@"renamed.bin"}]});
	require([[NSData dataWithContentsOfFile:[source stringByAppendingPathComponent:file[@"path"]]] isEqual:original] && ![fm fileExistsAtPath:[source stringByAppendingPathComponent:@"renamed.bin"]], "Failed rename journal changed source files");
	NSString *move = [root stringByAppendingPathComponent:@"move"];
	failCommand(engine, @"move", @{@"id":@"fixture", @"destination":move});
	require(![fm fileExistsAtPath:move], "Failed move journal started moving files");
	failCommand(engine, @"export", @{@"id":@"fixture"}); failCommand(engine, @"shutdown", @{});
	for (NSString *path in saved) require([[NSData dataWithContentsOfFile:path] isEqual:saved[path]], "ENOSPC changed the previous engine state generation");
	[fillerHandle closeFile]; require([fm removeItemAtPath:filler error:nil], "Cannot free disposable disk space");
	call(engine, @"retry", @{@"id":@"fixture"});
	NSData *exported = call(engine, @"export", @{@"id":@"fixture"}); require(exported.length > 0, "Export did not recover after space was freed");
	call(engine, @"shutdown", @{});
	printf("PASS: actual ENOSPC import rollback, rename/move journal safety, export/shutdown failure and recovery\n"); return 0;
} catch (std::exception const& error) { fprintf(stderr, "FAIL: %s\n", error.what()); return 1; } } }
