/* Narrow Darwin declarations from libarchive 3.7.4 archive.h/archive_entry.h.
 * Upstream: https://github.com/libarchive/libarchive/tree/v3.7.4/libarchive
 * Copyright (c) 2003-2010 Tim Kientzle
 * Copyright (c) 2016 Martin Matuska
 * Distributed under the two-clause BSD license in LICENSE. */
#ifndef MAXPLORER_CARCHIVE_SHIM_H
#define MAXPLORER_CARCHIVE_SHIM_H
#include <sys/types.h>
#include <stdint.h>
#include <stddef.h>
#include <time.h>
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_filter_none(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_7zip(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_open_fd(struct archive *, int, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
int archive_read_has_encrypted_entries(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_format_name(struct archive *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
long archive_entry_mtime_nsec(struct archive_entry *);
#endif
