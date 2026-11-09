// Included after the shared engine fixture helpers; no extra test framework.
static void rejects(ButterEngine *engine, NSString *command, NSDictionary *payload) {
	bool rejected = false;
	try { call(engine, command, payload); } catch (std::exception const&) { rejected = true; }
	require(rejected, "Malformed engine command was accepted");
}
static void validationCases(ButterEngine *engine, NSString *torrent, NSString *destination) {
	for (id value in @[@1, NSNull.null, @[], @{}]) {
		rejects(engine, @"inspect", @{@"source":value});
		rejects(engine, @"add", @{@"id":value, @"source":torrent, @"destination":destination});
		rejects(engine, @"settings", @{@"port":[value isEqual:@1] ? @1.5 : value});
	}
	for (NSString *key in @[@"../escape", @"/absolute", @"", @"a/b", @".", @"a.b"])
		rejects(engine, @"add", @{@"id":key, @"source":torrent, @"destination":destination});
	rejects(engine, @"blocklist", @{@"ranges":@[@{@"first":@"127.0.0.1", @"last":@"::1"}]});
	rejects(engine, @"blocklist", @{@"ranges":@[@{@"first":@"127.0.0.2", @"last":@"127.0.0.1"}]});
	rejects(engine, @"move", @{@"id":@"fixture", @"destination":@"relative"});
	rejects(engine, @"add", @{@"id":@"fixture", @"source":torrent, @"destination":destination});
	rejects(engine, @"rename", @{@"id":@"fixture", @"changes":@[@{@"path":@"x"}]});
	rejects(engine, @"rename", @{@"id":@"fixture", @"changes":@[@{@"index":@0, @"path":@"x"}, @{@"index":@0, @"path":@"y"}]});
	printf("PASS: bridge types, identifiers, occupied IDs and duplicate rename indices\n");
}
static void exportCases(ButterEngine *engine, NSString *torrent, NSString *destination) {
	for (NSString *ending in @[@"none", @"remove", @"shutdown"]) {
		NSString *key = [@"export-" stringByAppendingString:ending];
		call(engine, @"add", @{@"id":key, @"source":torrent, @"destination":destination});
		auto done = dispatch_group_create();
		__block int callbacks = 0;
		__block int successes = 0;
		NSData *input = [NSJSONSerialization dataWithJSONObject:@{@"id":key} options:0 error:nil];
		for (int index = 0; index < 64; ++index) {
			dispatch_group_enter(done);
			[engine perform:@"export" payload:input completion:^(NSData *data, NSString *error) {
				++callbacks; if (data.length && !error) ++successes;
				dispatch_group_leave(done);
			}];
		}
		if ([ending isEqual:@"remove"]) call(engine, @"remove", @{@"id":key});
		if ([ending isEqual:@"shutdown"]) call(engine, @"shutdown", @{});
		// No snapshot pump: the bridge must drive its own asynchronous requests.
		require(dispatch_group_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) == 0, "Concurrent exports did not all complete");
		require(callbacks == 64, "Export callback count differs from request count");
		if (![ending isEqual:@"remove"]) require(successes == 64, "Concurrent export failed");
		if (![ending isEqual:@"remove"]) call(engine, @"remove", @{@"id":key});
	}
	printf("PASS: 192 overlapping export requests, autonomous draining, removal and shutdown\n");
}
static void filesystemCases(ButterEngine *engine, NSString *torrent, NSString *source, NSString *destination, NSString *storage) {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSData *original = [NSData dataWithContentsOfFile:source];
	NSString *linkedDestination = [storage stringByAppendingPathComponent:@"symlink-destination"];
	require([fm createDirectoryAtPath:linkedDestination withIntermediateDirectories:YES attributes:nil error:nil], "Cannot create symlink fixture");
	require([fm createSymbolicLinkAtPath:[linkedDestination stringByAppendingPathComponent:source.lastPathComponent] withDestinationPath:source error:nil], "Cannot create managed-file symlink");
	rejects(engine, @"add", @{@"id":@"symlink", @"source":torrent, @"destination":linkedDestination});
	NSString *journal = [storage stringByAppendingPathComponent:@"unsafe-journal.paths.json"];
	for (id paths in @[@[], @[@{@"index":NSNull.null, @"path":@"safe"}], @[@{@"index":@0, @"path":@"../escape"}]]) {
		NSData *bytes = [NSJSONSerialization dataWithJSONObject:@{@"paths":paths, @"pending":@[]} options:0 error:nil];
		require([bytes writeToFile:journal atomically:YES], "Cannot create malformed journal fixture");
		rejects(engine, @"add", @{@"id":@"unsafe-journal", @"source":torrent, @"destination":destination, @"restore":@YES});
	}
	[fm removeItemAtPath:journal error:nil];
	NSString *other = decode(call(engine, @"create", @{@"id":@"private-meta", @"source":source, @"private":@YES, @"trackers":@[@"http://127.0.0.1:1/announce"]}))[@"source"];
	call(engine, @"add", @{@"id":@"shared-public", @"source":torrent, @"destination":destination});
	call(engine, @"add", @{@"id":@"shared-private", @"source":other, @"destination":destination});
	rejects(engine, @"remove", @{@"id":@"shared-public", @"trash":@YES});
	require([[NSData dataWithContentsOfFile:source] isEqual:original], "Shared-file refusal changed source bytes");
	call(engine, @"remove", @{@"id":@"shared-private"});
	call(engine, @"remove", @{@"id":@"shared-public"});
	call(engine, @"add", @{@"id":@"save-failure", @"source":torrent, @"destination":destination});
	NSString *resume = [storage stringByAppendingPathComponent:@"save-failure.resume"];
	for (int index = 0; index < 100 && ![fm fileExistsAtPath:resume]; ++index) { snapshot(engine); std::this_thread::sleep_for(std::chrono::milliseconds(10)); }
	require([fm fileExistsAtPath:resume], "Initial resume fixture missing");
	[fm removeItemAtPath:resume error:nil];
	require([fm createDirectoryAtPath:resume withIntermediateDirectories:NO attributes:nil error:nil], "Cannot inject resume write failure");
	rejects(engine, @"export", @{@"id":@"save-failure"});
	require([fm fileExistsAtPath:[storage stringByAppendingPathComponent:@"save-failure.torrent"]], "Failed resume write lost original metadata");
	rejects(engine, @"shutdown", @{});
	[fm removeItemAtPath:resume error:nil];
	call(engine, @"shutdown", @{});
	call(engine, @"remove", @{@"id":@"save-failure"});
	call(engine, @"add", @{@"id":@"retained", @"source":torrent, @"destination":destination});
	call(engine, @"remove", @{@"id":@"retained", @"retainState":@YES});
	NSString *retained = [storage stringByAppendingPathComponent:@"retained.torrent"];
	require([fm fileExistsAtPath:retained], "Removal discarded metadata before state commit");
	call(engine, @"add", @{@"id":@"retained", @"source":retained, @"destination":destination, @"restore":@YES});
	call(engine, @"remove", @{@"id":@"retained", @"retainState":@YES});
	call(engine, @"forget", @{@"id":@"retained"});
	require(![fm fileExistsAtPath:retained], "Committed removal did not discard retained metadata");
	printf("PASS: shared-file Trash refusal, failed resume/export callbacks and shutdown retry\n");
}
static void metadataVariantCases(NSString *root, NSString *source, NSString *destination, NSDictionary *baseSettings) {
	for (bool v2 : {false, true}) {
		NSString *name = v2 ? @"v2" : @"v1";
		auto files = lt::list_files(source.UTF8String);
		lt::create_torrent creator(std::move(files), 16384, v2 ? lt::create_torrent::v2_only : lt::create_torrent::v1_only);
		lt::error_code error;
		lt::set_piece_hashes(creator, destination.UTF8String, error);
		require(!error, "Could not hash independent metadata fixture");
		std::vector<char> bytes; lt::bencode(std::back_inserter(bytes), creator.generate());
		NSString *torrent = [root stringByAppendingPathComponent:[name stringByAppendingString:@".torrent"]];
		require([[NSData dataWithBytes:bytes.data() length:bytes.size()] writeToFile:torrent atomically:YES], "Cannot write independent metadata fixture");
		ButterEngine *seed = [[ButterEngine alloc] initWithStorage:[root stringByAppendingPathComponent:[name stringByAppendingString:@"-seed"]]];
		ButterEngine *download = [[ButterEngine alloc] initWithStorage:[root stringByAppendingPathComponent:[name stringByAppendingString:@"-engine"]]];
		NSMutableDictionary *settings = [baseSettings mutableCopy]; settings[@"tcp"] = @YES; settings[@"utp"] = @NO;
		call(seed, @"settings", settings); call(download, @"settings", settings);
		NSArray *hashes = decode(call(seed, @"inspect", @{@"source":torrent}))[@"hashes"];
		require(hashes.count == 1 && [hashes[0] length] == (v2 ? 64 : 40), "Fixture is not independently v1/v2");
		NSString *output = [root stringByAppendingPathComponent:[name stringByAppendingString:@"-download"]];
		call(seed, @"add", @{@"id":@"variant", @"source":torrent, @"destination":destination});
		call(download, @"add", @{@"id":@"variant", @"source":torrent, @"destination":output});
		call(seed, @"run", @{@"id":@"variant", @"running":@YES}); call(download, @"run", @{@"id":@"variant", @"running":@YES});
		bool complete = false;
		for (int index = 0; index < 1200; ++index) {
			NSDictionary *row = [snapshot(download)[@"transfers"] firstObject];
			if ([row[@"complete"] boolValue] && [row[@"wanted"] longLongValue] > 0 && [row[@"done"] isEqual:row[@"wanted"]]) { complete = true; break; }
			NSDictionary *bound = snapshot(seed);
			if (index % 20 == 0 && [bound[@"port"] intValue]) call(download, @"connect", @{@"id":@"variant", @"address":@"127.0.0.1", @"port":bound[@"port"]});
			std::this_thread::sleep_for(std::chrono::milliseconds(25));
		}
		require(complete, "Independent v1/v2 fixture did not transfer");
		// Completion can precede the final disk write. The shutdown save is a flush barrier.
		call(download, @"shutdown", @{});
		require([[NSData dataWithContentsOfFile:[output stringByAppendingPathComponent:source.lastPathComponent]] isEqual:[NSData dataWithContentsOfFile:source]], "Independent transfer bytes differ");
		call(seed, @"shutdown", @{});
	}
	printf("PASS: independent v1-only and v2-only metadata, loopback transfers and byte verification\n");
}
