#ifndef EXPLORER_CMTP_H
#define EXPLORER_CMTP_H
#include <stdint.h>
#include <stddef.h>
typedef struct CMTPContext CMTPContext;
typedef struct CMTPDevice CMTPDevice;
typedef int (*CMTPProgress)(uint64_t, uint64_t, const void *);
typedef struct {
    char *key;
    char *name;
} CMTPCandidate;
typedef struct {
    uint32_t id;
    char *name;
    int writable;
} CMTPStorage;
typedef struct {
    uint32_t id;
    uint32_t parent;
    uint32_t storage;
    char *name;
    uint64_t size;
    int64_t modified;
    int folder;
} CMTPObject;
CMTPContext *cmtp_load(void);
void cmtp_unload(CMTPContext *);
int cmtp_detect(CMTPContext *, CMTPCandidate **, size_t *);
void cmtp_free_candidates(CMTPCandidate *, size_t);
CMTPDevice *cmtp_open(CMTPContext *, const char *);
void cmtp_close(CMTPDevice *);
char *cmtp_name(CMTPDevice *);
char *cmtp_serial(CMTPDevice *);
char *cmtp_error(CMTPDevice *);
int cmtp_cancelled(CMTPDevice *);
int cmtp_connection_failed(CMTPDevice *);
int cmtp_storages(CMTPDevice *, CMTPStorage **, size_t *);
void cmtp_free_storages(CMTPStorage *, size_t);
int cmtp_list(CMTPDevice *, uint32_t, uint32_t, CMTPObject **, size_t *);
void cmtp_free_objects(CMTPObject *, size_t);
int cmtp_download(CMTPDevice *, uint32_t, int, CMTPProgress, const void *);
int cmtp_upload(CMTPDevice *, int, const char *, uint64_t, uint32_t, uint32_t, uint32_t *, CMTPProgress, const void *);
uint32_t cmtp_mkdir(CMTPDevice *, const char *, uint32_t, uint32_t);
int cmtp_rename(CMTPDevice *, uint32_t, const char *);
int cmtp_remove(CMTPDevice *, uint32_t);
void cmtp_free(void *);
#endif
