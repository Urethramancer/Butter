import Testing

// Independent session worlds share the production disk queue. Each case retains
// its own concurrent transfers, commands and transports without competing fixtures.
@Suite(.serialized) struct NativeSessionTests {}
