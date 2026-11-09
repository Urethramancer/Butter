#pragma once
#import "ButterEngine.h"
#import <Foundation/Foundation.h>
#include <thread>
#include <chrono>
#include <stdexcept>
#include <unistd.h>
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
