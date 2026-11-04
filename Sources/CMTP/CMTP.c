#include "CMTP.h"
#include "libmtp_abi.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
struct CMTPContext {
    void *library;
    LIBMTP_raw_device_t *raw;
    int count;
    void (*Init)(void);
    int (*Detect_Raw_Devices)(LIBMTP_raw_device_t **, int *);
    LIBMTP_mtpdevice_t *(*Open_Raw_Device_Uncached)(LIBMTP_raw_device_t *);
    void (*Release_Device)(LIBMTP_mtpdevice_t *);
    char *(*Get_Friendlyname)(LIBMTP_mtpdevice_t *);
    char *(*Get_Modelname)(LIBMTP_mtpdevice_t *);
    char *(*Get_Serialnumber)(LIBMTP_mtpdevice_t *);
    int (*Get_Storage)(LIBMTP_mtpdevice_t *, int);
    LIBMTP_error_t *(*Get_Errorstack)(LIBMTP_mtpdevice_t *);
    void (*Clear_Errorstack)(LIBMTP_mtpdevice_t *);
    int (*Get_Children)(LIBMTP_mtpdevice_t *, uint32_t, uint32_t, uint32_t **);
    LIBMTP_file_t *(*Get_Filemetadata)(LIBMTP_mtpdevice_t *, uint32_t);
    LIBMTP_file_t *(*new_file_t)(void);
    void (*destroy_file_t)(LIBMTP_file_t *);
    int (*Get_File_To_File_Descriptor)(LIBMTP_mtpdevice_t *, uint32_t, int, CMTPProgress, const void *);
    int (*Send_File_From_File_Descriptor)(LIBMTP_mtpdevice_t *, int, LIBMTP_file_t *, CMTPProgress, const void *);
    uint32_t (*Create_Folder)(LIBMTP_mtpdevice_t *, char *, uint32_t, uint32_t);
    int (*Set_Object_Filename)(LIBMTP_mtpdevice_t *, uint32_t, char *);
    int (*Delete_Object)(LIBMTP_mtpdevice_t *, uint32_t);
};
struct CMTPDevice {
    CMTPContext *context;
    LIBMTP_mtpdevice_t *device;
};
#define LOAD(name) \
    *(void **)(&c->name) = dlsym(c->library, "LIBMTP_" #name); \
    if (!c->name) { \
        cmtp_unload(c); \
        return NULL; \
    }
CMTPContext *cmtp_load(void) {
    CMTPContext *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->library = dlopen("/opt/homebrew/lib/libmtp.9.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!c->library) c->library = dlopen("/usr/local/lib/libmtp.9.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!c->library) {
        free(c);
        return NULL;
    }
    LOAD(Init);
    LOAD(Detect_Raw_Devices);
    LOAD(Open_Raw_Device_Uncached);
    LOAD(Release_Device);
    LOAD(Get_Friendlyname);
    LOAD(Get_Modelname);
    LOAD(Get_Serialnumber);
    LOAD(Get_Storage);
    LOAD(Get_Errorstack);
    LOAD(Clear_Errorstack);
    LOAD(Get_Children);
    LOAD(Get_Filemetadata);
    LOAD(new_file_t);
    LOAD(destroy_file_t);
    LOAD(Get_File_To_File_Descriptor);
    LOAD(Send_File_From_File_Descriptor);
    LOAD(Create_Folder);
    LOAD(Set_Object_Filename);
    LOAD(Delete_Object);
    c->Init();
    return c;
}
void cmtp_unload(CMTPContext *c) {
    if (!c) return;
    free(c->raw);
    if (c->library) dlclose(c->library);
    free(c);
}
static void key(LIBMTP_raw_device_t *r, char *out, size_t n) {
    snprintf(out, n, "%04x:%04x:%u:%u", r->device_entry.vendor_id, r->device_entry.product_id, r->bus_location, r->devnum);
}
int cmtp_detect(CMTPContext *c, CMTPCandidate **out, size_t *count) {
    *out = NULL;
    *count = 0;
    free(c->raw);
    c->raw = NULL;
    c->count = 0;
    int status = c->Detect_Raw_Devices(&c->raw, &c->count);
    if (status == 5) return 0;
    if (status != 0 || c->count < 0) return -1;
    CMTPCandidate *result = calloc((size_t)c->count, sizeof(*result));
    if (c->count && !result) return -1;
    int i = 0;
    while (i < c->count) {
        char k[128];
        key(&c->raw[i], k, sizeof(k));
        result[i].key = strdup(k);
        result[i].name = strdup(c->raw[i].device_entry.product ? c->raw[i].device_entry.product : "MTP Device");
        if (!result[i].key || !result[i].name) {
            cmtp_free_candidates(result, (size_t)c->count);
            return -1;
        }
        i++;
    }
    *out = result;
    *count = (size_t)c->count;
    return 0;
}
void cmtp_free_candidates(CMTPCandidate *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        free(p[i].key);
        free(p[i].name);
        i++;
    }
    free(p);
}
CMTPDevice *cmtp_open(CMTPContext *c, const char *wanted) {
    int i = 0;
    while (i < c->count) {
        char k[128];
        key(&c->raw[i], k, sizeof(k));
        if (strcmp(k, wanted) == 0) {
            LIBMTP_mtpdevice_t *d = c->Open_Raw_Device_Uncached(&c->raw[i]);
            if (!d) return NULL;
            CMTPDevice *result = calloc(1, sizeof(*result));
            if (!result) {
                c->Release_Device(d);
                return NULL;
            }
            result->context = c;
            result->device = d;
            return result;
        }
        i++;
    }
    return NULL;
}
void cmtp_close(CMTPDevice *d) {
    if (!d) return;
    d->context->Release_Device(d->device);
    free(d);
}
char *cmtp_name(CMTPDevice *d) {
    char *name = d->context->Get_Friendlyname(d->device);
    if (name && name[0] == '\0') {
        free(name);
        name = NULL;
    }
    if (!name) name = d->context->Get_Modelname(d->device);
    return name;
}
char *cmtp_serial(CMTPDevice *d) {
    return d->context->Get_Serialnumber(d->device);
}
char *cmtp_error(CMTPDevice *d) {
    LIBMTP_error_t *error = d->context->Get_Errorstack(d->device);
    return error && error->error_text ? strdup(error->error_text) : NULL;
}
int cmtp_cancelled(CMTPDevice *d) {
    LIBMTP_error_t *error = d->context->Get_Errorstack(d->device);
    while (error) {
        if (error->errornumber == 8) return 1;
        error = error->next;
    }
    return 0;
}
int cmtp_connection_failed(CMTPDevice *d) {
    LIBMTP_error_t *error = d->context->Get_Errorstack(d->device);
    while (error) {
        if (error->errornumber == 3 || error->errornumber == 5 || error->errornumber == 7) return 1;
        error = error->next;
    }
    return 0;
}
int cmtp_storages(CMTPDevice *d, CMTPStorage **out, size_t *count) {
    *out = NULL;
    *count = 0;
    CMTPContext *c = d->context;
    c->Clear_Errorstack(d->device);
    if (c->Get_Storage(d->device, 0) != 0 || c->Get_Errorstack(d->device)) return -1;
    LIBMTP_devicestorage_t *p = d->device->storage;
    size_t n = 0;
    while (p && n < 65536) {
        n++;
        p = p->next;
    }
    if (p) return -1;
    CMTPStorage *result = calloc(n, sizeof(*result));
    if (n && !result) return -1;
    p = d->device->storage;
    size_t i = 0;
    while (p) {
        result[i].id = p->id;
        result[i].writable = p->AccessCapability == 0;
        result[i].name = strdup(p->StorageDescription ? p->StorageDescription : "Storage");
        if (!result[i].name) {
            cmtp_free_storages(result, n);
            return -1;
        }
        p = p->next;
        i++;
    }
    *out = result;
    *count = n;
    return 0;
}
void cmtp_free_storages(CMTPStorage *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        free(p[i].name);
        i++;
    }
    free(p);
}
int cmtp_list(CMTPDevice *d, uint32_t storage, uint32_t parent, CMTPObject **out, size_t *count) {
    *out = NULL;
    *count = 0;
    CMTPContext *c = d->context;
    c->Clear_Errorstack(d->device);
    uint32_t *handles = NULL;
    int length = c->Get_Children(d->device, storage, parent, &handles);
    if (length < 0 || length > 100000 || (length > 0 && !handles) || c->Get_Errorstack(d->device)) {
        free(handles);
        return -1;
    }
    size_t n = (size_t)length;
    CMTPObject *result = calloc(n, sizeof(*result));
    if (n && !result) {
        free(handles);
        return -1;
    }
    int failed = 0;
    size_t i = 0;
    while (i < n && !failed) {
        LIBMTP_file_t *metadata = c->Get_Filemetadata(d->device, handles[i]);
        if (!metadata) {
            failed = 1;
        } else {
            result[i] = (CMTPObject){metadata->item_id, metadata->parent_id, metadata->storage_id,
                strdup(metadata->filename ? metadata->filename : ""), metadata->filesize,
                metadata->modificationdate, metadata->filetype == LIBMTP_FILETYPE_FOLDER};
            if (!result[i].name || result[i].id != handles[i] || c->Get_Errorstack(d->device)) failed = 1;
            // Metadata is normally a single node. Destroy every owned node if that changes.
            while (metadata) {
                LIBMTP_file_t *next = metadata->next;
                metadata->next = NULL;
                c->destroy_file_t(metadata);
                metadata = next;
            }
        }
        i++;
    }
    free(handles);
    if (failed) {
        cmtp_free_objects(result, n);
        return -1;
    }
    *out = result;
    *count = n;
    return 0;
}
void cmtp_free_objects(CMTPObject *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        free(p[i].name);
        i++;
    }
    free(p);
}
int cmtp_download(CMTPDevice *d, uint32_t id, int fd, CMTPProgress cb, const void *data) {
    d->context->Clear_Errorstack(d->device);
    return d->context->Get_File_To_File_Descriptor(d->device, id, fd, cb, data);
}
int cmtp_upload(CMTPDevice *d, int fd, const char *name, uint64_t size, uint32_t storage, uint32_t parent, uint32_t *id, CMTPProgress cb, const void *data) {
    LIBMTP_file_t *f = d->context->new_file_t();
    *id = 0;
    if (!f) return -1;
    f->filename = strdup(name);
    if (!f->filename) {
        d->context->destroy_file_t(f);
        return -1;
    }
    f->filesize = size;
    f->storage_id = storage;
    f->parent_id = parent;
    f->filetype = LIBMTP_FILETYPE_UNKNOWN;
    struct stat source;
    if (fstat(fd, &source) == 0) f->modificationdate = source.st_mtime;
    d->context->Clear_Errorstack(d->device);
    int status = d->context->Send_File_From_File_Descriptor(d->device, fd, f, cb, data);
    *id = f->item_id;
    d->context->destroy_file_t(f);
    return status;
}
uint32_t cmtp_mkdir(CMTPDevice *d, const char *name, uint32_t storage, uint32_t parent) {
    d->context->Clear_Errorstack(d->device);
    char *mutable_name = strdup(name);
    if (!mutable_name) return 0;
    uint32_t id = d->context->Create_Folder(d->device, mutable_name, parent, storage);
    free(mutable_name);
    return id;
}
int cmtp_rename(CMTPDevice *d, uint32_t id, const char *name) {
    d->context->Clear_Errorstack(d->device);
    char *mutable_name = strdup(name);
    if (!mutable_name) return -1;
    int status = d->context->Set_Object_Filename(d->device, id, mutable_name);
    free(mutable_name);
    return status;
}
int cmtp_remove(CMTPDevice *d, uint32_t id) {
    d->context->Clear_Errorstack(d->device);
    return d->context->Delete_Object(d->device, id);
}
void cmtp_free(void *p) {
    free(p);
}
