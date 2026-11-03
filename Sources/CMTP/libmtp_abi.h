/* ABI subset from libmtp src/libmtp.h.in, verified 2026-11-03.
 * Copyright (C) 2005-2013 Linus Walleij
 * Copyright (C) 2005-2008 Richard A. Low
 * Copyright (C) 2007 Ted Bullock
 * Copyright (C) 2008 Florent Mertens
 * LGPL version 2 or later. See Support/libmtp/COPYING.
 * Only declarations used by the optional runtime bridge are reproduced.
 */
#include <stdint.h>
#include <time.h>
enum {
    LIBMTP_FILETYPE_FOLDER = 0,
    LIBMTP_FILETYPE_UNKNOWN = 44
};
typedef struct {
    char *vendor;
    uint16_t vendor_id;
    char *product;
    uint16_t product_id;
    uint32_t device_flags;
} LIBMTP_device_entry_t;
typedef struct {
    LIBMTP_device_entry_t device_entry;
    uint32_t bus_location;
    uint8_t devnum;
} LIBMTP_raw_device_t;
typedef struct LIBMTP_error_struct {
    int errornumber;
    char *error_text;
    struct LIBMTP_error_struct *next;
} LIBMTP_error_t;
typedef struct LIBMTP_devicestorage_struct {
    uint32_t id;
    uint16_t StorageType;
    uint16_t FilesystemType;
    uint16_t AccessCapability;
    uint64_t MaxCapacity;
    uint64_t FreeSpaceInBytes;
    uint64_t FreeSpaceInObjects;
    char *StorageDescription;
    char *VolumeIdentifier;
    struct LIBMTP_devicestorage_struct *next;
    struct LIBMTP_devicestorage_struct *prev;
} LIBMTP_devicestorage_t;
/* Only the stable public prefix is accessed. The library owns this allocation. */
typedef struct {
    uint8_t object_bitsize;
    void *params;
    void *usbinfo;
    LIBMTP_devicestorage_t *storage;
} LIBMTP_mtpdevice_t;
typedef struct LIBMTP_file_struct {
    uint32_t item_id;
    uint32_t parent_id;
    uint32_t storage_id;
    char *filename;
    uint64_t filesize;
    time_t modificationdate;
    int filetype;
    struct LIBMTP_file_struct *next;
} LIBMTP_file_t;
