// Minimal declarations for the libarchive 3.x C API shipped with macOS.
// Only the functions Explorer uses are declared. ABI per libarchive 3.7.
#ifndef CARCHIVE_H
#define CARCHIVE_H

#include <sys/types.h>
#include <stdint.h>
#include <stddef.h>
#include <time.h>

#define ARCHIVE_EOF       1
#define ARCHIVE_OK        0
#define ARCHIVE_RETRY   (-10)
#define ARCHIVE_WARN    (-20)
#define ARCHIVE_FAILED  (-25)
#define ARCHIVE_FATAL   (-30)

#define ARCHIVE_EXTRACT_TIME   (0x0004)
#define ARCHIVE_EXTRACT_PERM   (0x0002)
#define ARCHIVE_EXTRACT_ACL    (0x0020)
#define ARCHIVE_EXTRACT_FFLAGS (0x0040)
#define ARCHIVE_EXTRACT_XATTR  (0x0080)
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS (0x0100)
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT (0x0200)

static const unsigned int AE_IFMT  = 0170000;
static const unsigned int AE_IFREG = 0100000;
static const unsigned int AE_IFLNK = 0120000;
static const unsigned int AE_IFDIR = 0040000;

struct archive;
struct archive_entry;

typedef ssize_t ca_read_callback(struct archive *, void *_client_data, const void **_buffer);
typedef int64_t ca_seek_callback(struct archive *, void *_client_data, int64_t offset, int whence);
typedef int64_t ca_skip_callback(struct archive *, void *_client_data, int64_t request);
typedef int ca_open_callback(struct archive *, void *_client_data);
typedef int ca_close_callback(struct archive *, void *_client_data);
typedef int ca_switch_callback(struct archive *, void *_client_data1, void *_client_data2);

const char *archive_version_string(void);
int archive_errno(struct archive *);
const char *archive_error_string(struct archive *);
int archive_format(struct archive *);
const char *archive_format_name(struct archive *);
const char *archive_filter_name(struct archive *, int);

// Read
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_support_format_empty(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_set_options(struct archive *, const char *opts);
int archive_read_set_format_option(struct archive *, const char *m, const char *o, const char *v);
int archive_read_open_filename(struct archive *, const char *_filename, size_t _block_size);
int archive_read_open_filenames(struct archive *, const char **_filenames, size_t _block_size);
int archive_read_open_memory(struct archive *, const void * buff, size_t size);
int archive_read_set_open_callback(struct archive *, ca_open_callback *);
int archive_read_set_read_callback(struct archive *, ca_read_callback *);
int archive_read_set_seek_callback(struct archive *, ca_seek_callback *);
int archive_read_set_skip_callback(struct archive *, ca_skip_callback *);
int archive_read_set_close_callback(struct archive *, ca_close_callback *);
int archive_read_set_switch_callback(struct archive *, ca_switch_callback *);
int archive_read_set_callback_data(struct archive *, void *);
int archive_read_append_callback_data(struct archive *, void *);
int archive_read_open1(struct archive *);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_data_into_fd(struct archive *, int fd);
int archive_read_has_encrypted_entries(struct archive *);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);

// Write
struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_set_format_7zip(struct archive *);
int archive_write_set_format_pax_restricted(struct archive *);
int archive_write_set_format_raw(struct archive *);
int archive_write_set_format_by_name(struct archive *, const char *name);
int archive_write_add_filter_gzip(struct archive *);
int archive_write_add_filter_bzip2(struct archive *);
int archive_write_add_filter_xz(struct archive *);
int archive_write_add_filter_lz4(struct archive *);
int archive_write_add_filter_none(struct archive *);
int archive_write_add_filter_by_name(struct archive *, const char *name);
int archive_write_set_options(struct archive *, const char *opts);
int archive_write_set_passphrase(struct archive *, const char *p);
int archive_write_open_filename(struct archive *, const char *_file);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *, size_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

// Disk writer
struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int flags);
int archive_write_disk_set_standard_lookup(struct archive *);

// Entry
struct archive_entry *archive_entry_new(void);
struct archive_entry *archive_entry_clone(struct archive_entry *);
void archive_entry_free(struct archive_entry *);
void archive_entry_clear(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
void archive_entry_set_pathname_utf8(struct archive_entry *, const char *);
void archive_entry_copy_pathname(struct archive_entry *, const char *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
void archive_entry_set_size(struct archive_entry *, int64_t);
unsigned int archive_entry_filetype(struct archive_entry *);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
unsigned int archive_entry_perm(struct archive_entry *);
void archive_entry_set_perm(struct archive_entry *, unsigned int);
time_t archive_entry_mtime(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
void archive_entry_set_mtime(struct archive_entry *, time_t, long);
const char *archive_entry_symlink(struct archive_entry *);
void archive_entry_set_symlink(struct archive_entry *, const char *);
int archive_entry_is_encrypted(struct archive_entry *);
int archive_entry_is_data_encrypted(struct archive_entry *);

#endif
