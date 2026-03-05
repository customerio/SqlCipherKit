/**
 * SqlCipher public umbrella header for the CSqlCipher Swift module.
 *
 * sqlite3_key and sqlite3_rekey are normally guarded by #ifdef SQLITE_HAS_CODEC
 * inside sqlite3.h.  That guard is satisfied when *compiling* sqlite3.c
 * (the cSettings define propagates to the C compiler), but SPM does not
 * forward cSettings defines to the Swift compiler when it imports a C module.
 *
 * We work around this by including sqlite3.h first (for the full SQLite
 * surface) and then unconditionally redeclaring the cipher functions so that
 * they are always visible to Swift — safe because the symbols are always
 * present in the compiled sqlite3.c.
 */

#pragma once

#include "sqlite3.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Set the encryption key for a newly-opened database.
 * Must be called immediately after sqlite3_open and before any other
 * operation on the database.  Returns SQLITE_OK on success.
 */
SQLITE_API int sqlite3_key(
    sqlite3 *db,
    const void *pKey,
    int nKey
);

/**
 * Set the encryption key for a named database attached to `db`.
 */
SQLITE_API int sqlite3_key_v2(
    sqlite3 *db,
    const char *zDbName,
    const void *pKey,
    int nKey
);

/**
 * Change the encryption key for an open database.
 * Rewrites every page; may be slow on large databases.
 */
SQLITE_API int sqlite3_rekey(
    sqlite3 *db,
    const void *pKey,
    int nKey
);

/**
 * Change the encryption key for a named database attached to `db`.
 */
SQLITE_API int sqlite3_rekey_v2(
    sqlite3 *db,
    const char *zDbName,
    const void *pKey,
    int nKey
);

#ifdef __cplusplus
}
#endif
