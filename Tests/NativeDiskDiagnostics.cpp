// Diagnostic only: link the pinned library without changing acceptance binaries.
#include <libtorrent/pread_disk_io.hpp>
#include <libtorrent/disk_interface.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/storage_defs.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/performance_counters.hpp>
#include <libtorrent/hasher.hpp>
#include <libtorrent/aux_/vector.hpp>
#include <libtorrent/io_context.hpp>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
namespace lt = libtorrent;
constexpr int block = 16384, piece = 262144;
void require(bool ok, char const* message) { if (!ok) throw std::runtime_error(message); }
void probe(std::filesystem::path const& root, bool partial, bool upload) {
	std::vector<char> bytes(piece);
	for (int i = 0; i < piece; ++i) bytes[i] = char((i * 17 + i / 97) % 251);
	std::ofstream file(root / "payload", std::ios::binary); file.write(bytes.data(), bytes.size()); file.close();
	require(bool(file), "fixture write");
	lt::io_context io; lt::counters counters;
	auto settings = lt::default_settings();
	// Hold exactly one dirty cached block deterministically, with no hasher race.
	// These probe settings are deliberately separate from headline benchmarks.
	settings.set_int(lt::settings_pack::aio_threads, 0);
	settings.set_int(lt::settings_pack::hashing_threads, 0);
	auto disk = lt::pread_disk_io_constructor(io, settings, counters);
	lt::file_storage files; files.set_piece_length(piece); files.add_file("payload", piece, {}); files.set_num_pieces(1);
	lt::aux::vector<lt::download_priority_t, lt::file_index_t> priorities; lt::renamed_files renamed;
	auto const path = root.string();
	lt::storage_params params{files, renamed, path, {}, lt::storage_mode_t::storage_mode_sparse, priorities, lt::sha1_hash{}, true, true};
	auto storage = disk->new_torrent(params, std::shared_ptr<void>());
	bool closing = false;
	if (partial) disk->async_write(storage, {lt::piece_index_t{0}, 0, block}, bytes.data(), {}, [&](lt::storage_error const& error) { if (!closing) require(!error, "cached write"); }, {});
	int callbacks = 0; std::vector<lt::sha256_hash> hashes(piece / block);
	if (upload) {
		for (int offset = 0; offset < piece; offset += block) disk->async_read(storage, {lt::piece_index_t{0}, offset, block}, [&, offset](lt::disk_buffer_holder buffer, lt::storage_error const& error) {
			require(!error && buffer && std::memcmp(buffer.data(), bytes.data() + offset, block) == 0, "upload bytes"); ++callbacks;
		}, {});
	} else {
		disk->async_hash(storage, lt::piece_index_t{0}, lt::span<lt::sha256_hash>(hashes), lt::disk_interface::v1_hash, [&](lt::piece_index_t, lt::sha1_hash const& hash, lt::storage_error const& error) {
			lt::hasher sha1; sha1.update({bytes.data(), piece}); require(!error && hash == sha1.final(), "SHA-1 mismatch");
			for (int i = 0; i < piece / block; ++i) { lt::hasher256 sha256; sha256.update({bytes.data() + i * block, block}); require(hashes[i] == sha256.final(), "SHA-256 mismatch"); }
			++callbacks;
		});
	}
	disk->submit_jobs();
	auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
	while (callbacks < (upload ? piece / block : 1) && std::chrono::steady_clock::now() < deadline) { io.restart(); io.run_for(std::chrono::milliseconds(10)); }
	require(callbacks == (upload ? piece / block : 1), "completion timeout");
	disk->update_stats_counters(counters);
	auto reads = counters[lt::counters::num_read_ops];
	require(reads == (upload ? (partial ? 15 : 16) : (partial ? 30 : 1)), "unexpected read count");
	std::cout << "{\"case\":\"" << (upload ? "upload" : "hybrid-hash") << "\",\"cached_blocks\":" << int(partial)
		<< ",\"piece_bytes\":" << piece << ",\"request_bytes\":" << block << ",\"callbacks\":" << callbacks
		<< ",\"read_ops\":" << reads << ",\"read_back_blocks\":" << counters[lt::counters::num_read_back]
		<< ",\"blocks_read\":" << counters[lt::counters::num_blocks_read]
		<< ",\"file_pool_hits\":" << counters[lt::counters::file_pool_hits] << ",\"file_pool_misses\":" << counters[lt::counters::file_pool_misses]
		<< ",\"file_pool_thread_stall\":" << counters[lt::counters::file_pool_thread_stall] << ",\"file_pool_race\":" << counters[lt::counters::file_pool_race]
		<< ",\"validated\":true}" << std::endl;
	// Clearing the intentionally dirty cache cancels its pending write callback.
	closing = true; bool cleared = false;
	disk->async_clear_piece(storage, lt::piece_index_t{0}, [&](lt::piece_index_t) { cleared = true; }); disk->submit_jobs();
	deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
	while (!cleared && std::chrono::steady_clock::now() < deadline) { io.restart(); io.run_for(std::chrono::milliseconds(10)); }
	require(cleared, "cache cleanup timeout"); disk->abort(true);
}
int main(int argc, char** argv) {
	try { require(argc == 2, "expected scratch directory"); for (bool upload : {false, true}) for (bool partial : {false, true}) probe(argv[1], partial, upload); }
	catch (std::exception const& error) { std::cerr << error.what() << '\n'; return 1; }
}
