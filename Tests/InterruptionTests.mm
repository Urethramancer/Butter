#include "EngineTestSupport.h"
#include <sys/stat.h>
#include <sys/wait.h>
#include <signal.h>

static int const fileCount = 256;
static NSDictionary *jobAt(NSString *path) { return decode([NSData dataWithContentsOfFile:path]); }
static void child(NSDictionary *job) {
	ButterEngine *engine = [[ButterEngine alloc] initWithStorage:job[@"storage"]];
	call(engine, @"add", @{@"id":@"fixture", @"source":job[@"torrent"], @"destination":job[@"source"], @"restore":@YES});
	// A prior orderly save has verified the source; no public discovery or sockets are configured.
	if ([job[@"operation"] hasPrefix:@"move"]) call(engine, @"move", @{@"id":@"fixture", @"destination":job[@"target"]});
	else {
		NSMutableArray *changes = [NSMutableArray array];
		for (NSDictionary *file in decode(call(engine, @"inspect", @{@"source":job[@"torrent"]}))[@"files"]) {
			if ([file[@"pad"] boolValue]) continue;
			[changes addObject:@{@"index":file[@"index"], @"path":[@"renamed/" stringByAppendingString:[file[@"path"] lastPathComponent]]}];
		}
		call(engine, @"rename", @{@"id":@"fixture", @"changes":changes});
	}
	for (;;) { snapshot(engine); std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
}
static NSString *fileName(int index) { return [NSString stringWithFormat:@"file-%03d.bin", index]; }
static NSData *contents(int index) {
	NSMutableData *data = [NSMutableData dataWithLength:256 * 1024];
	for (NSUInteger offset = 0; offset < data.length; ++offset) ((unsigned char *)data.mutableBytes)[offset] = (index * 17 + offset * 31 + offset / 97) % 251;
	return data;
}
static void runCase(NSString *executable, NSString *root, NSString *volume, NSString *operation, int boundary) {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString *name = [NSString stringWithFormat:@"%@-%d", operation, boundary];
	NSString *fixture = [root stringByAppendingPathComponent:name], *source = [fixture stringByAppendingPathComponent:@"source"], *storage = [fixture stringByAppendingPathComponent:@"engine"];
	NSString *bundle = [source stringByAppendingPathComponent:@"bundle"];
	require([fm createDirectoryAtPath:bundle withIntermediateDirectories:YES attributes:nil error:nil], "Cannot create interruption fixture");
	for (int index = 0; index < fileCount; ++index) {
		NSData *data = contents(index);
		require([data writeToFile:[bundle stringByAppendingPathComponent:fileName(index)] atomically:YES], "Cannot write interruption source");
	}
	ButterEngine *preparer = [[ButterEngine alloc] initWithStorage:storage];
	NSString *torrent = decode(call(preparer, @"create", @{@"id":@"fixture", @"source":bundle, @"trackers":@[], @"private":@NO}))[@"source"];
	call(preparer, @"add", @{@"id":@"fixture", @"source":torrent, @"destination":source});
	call(preparer, @"run", @{@"id":@"fixture", @"running":@YES});
	bool complete = false;
	for (int index = 0; index < 1000; ++index) {
		NSDictionary *row = [snapshot(preparer)[@"transfers"] firstObject];
		if ([row[@"complete"] boolValue] && [row[@"wanted"] longLongValue] == fileCount * 256LL * 1024) { complete = true; break; }
		std::this_thread::sleep_for(std::chrono::milliseconds(5));
	}
	require(complete, "Interruption source did not verify"); call(preparer, @"shutdown", @{}); preparer = nil;
	NSString *target = [operation hasPrefix:@"move"] ? [volume stringByAppendingPathComponent:name] : source;
	NSString *targetFiles = [target stringByAppendingPathComponent:[operation hasPrefix:@"move"] ? @"bundle" : @"renamed"];
	NSString *job = [fixture stringByAppendingPathComponent:@"job.json"];
	require([[NSJSONSerialization dataWithJSONObject:@{@"storage":storage, @"source":source, @"torrent":torrent, @"target":target, @"operation":operation} options:0 error:nil] writeToFile:job atomically:YES], "Cannot write child job");
	NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:executable]; task.arguments = @[@"--child", job];
	NSError *error = nil; require([task launchAndReturnError:&error], "Cannot launch interruption child");
	bool stopped = false;
	@try {
		auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
		while (task.running && std::chrono::steady_clock::now() < deadline) {
			bool deleting = [operation isEqual:@"move-delete"];
			NSArray *paths = [fm contentsOfDirectoryAtPath:deleting ? bundle : targetFiles error:nil];
			if (deleting ? paths.count <= fileCount - boundary : paths.count >= boundary) {
				require(kill(task.processIdentifier, SIGSTOP) == 0, "Cannot stop interruption child");
				int status = 0; require(waitpid(task.processIdentifier, &status, WUNTRACED) == task.processIdentifier && WIFSTOPPED(status), "Child did not stop");
				stopped = true; break;
			}
			std::this_thread::sleep_for(std::chrono::microseconds(200));
		}
		require(stopped, "Did not observe requested filesystem boundary");
		NSUInteger arrived = [[fm contentsOfDirectoryAtPath:targetFiles error:nil] count];
		NSUInteger remaining = [[fm contentsOfDirectoryAtPath:bundle error:nil] count];
		if (![operation isEqual:@"move-delete"]) require(arrived < fileCount, "Operation completed before interruption; partial operation was not tested");
		else require(remaining > 0 && remaining < fileCount, "Did not interrupt partial source deletion");
		require(kill(task.processIdentifier, SIGKILL) == 0, "Cannot terminate interruption child"); [task waitUntilExit];
		// Verify complete bytes survive at either original or target path before recovery.
		for (int index = 0; index < fileCount; ++index) {
			NSData *old = [NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:fileName(index)]];
			NSData *moved = [NSData dataWithContentsOfFile:[targetFiles stringByAppendingPathComponent:fileName(index)]];
			NSData *valid = old.length == 256 * 1024 ? old : moved;
			require([valid isEqual:contents(index)], "Interrupted operation lost source bytes");
		}
		ButterEngine *restored = [[ButterEngine alloc] initWithStorage:storage];
		call(restored, @"add", @{@"id":@"fixture", @"source":torrent, @"destination":source, @"restore":@YES});
		NSDictionary *row = [snapshot(restored)[@"transfers"] firstObject];
		require([row[@"error"] length] > 0, "Interrupted operation did not require review");
		for (NSDictionary *file in row[@"files"]) {
			if ([file[@"pad"] boolValue]) continue;
			NSString *path = [row[@"path"] stringByAppendingPathComponent:file[@"path"]];
			require([fm fileExistsAtPath:path], "Recovery failed to locate a retained managed file");
			int index = [[[path lastPathComponent] substringWithRange:NSMakeRange(5, 3)] intValue];
			require([[NSData dataWithContentsOfFile:path] isEqual:contents(index)], "Recovered path does not contain the expected bytes");
		}
		call(restored, @"shutdown", @{});
		printf("PASS: %s killed with %lu target files and %lu originals; every recovered byte verified\n", operation.UTF8String, (unsigned long)arrived, (unsigned long)remaining);
	} @finally {
		if (task.running) { kill(task.processIdentifier, SIGKILL); [task waitUntilExit]; }
		[fm removeItemAtPath:target error:nil];
	}
}
int main(int argc, char **argv) { @autoreleasepool { try {
	if (argc == 3 && std::string(argv[1]) == "--child") { child(jobAt(@(argv[2]))); return 0; }
	require(argc == 3, "Expected temporary fixture root and mounted fixture volume");
	NSString *root = @(argv[1]), *volume = @(argv[2]);
	require([[NSFileManager defaultManager] fileExistsAtPath:[volume stringByAppendingPathComponent:@".butter-interruption-test"]], "Missing disposable-volume marker");
	struct stat source{}, target{}; require(stat(root.UTF8String, &source) == 0 && stat(volume.UTF8String, &target) == 0 && source.st_dev != target.st_dev, "Move fixture must span distinct devices");
	NSString *executable = [NSBundle.mainBundle executablePath];
	for (NSString *operation in @[@"rename", @"move", @"move-delete"]) for (int boundary : {1, 32, 128}) runCase(executable, root, volume, operation, boundary);
	return 0;
} catch (std::exception const& error) { fprintf(stderr, "FAIL: %s\n", error.what()); return 1; } } }
