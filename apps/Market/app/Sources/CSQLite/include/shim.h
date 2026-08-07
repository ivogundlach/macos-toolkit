// Re-export the system sqlite3 header so Swift can `import CSQLite`.
// Uses the SDK's sqlite3.h; we link against libsqlite3 (see module map / Package.swift).
#ifndef MARKET_CSQLITE_SHIM_H
#define MARKET_CSQLITE_SHIM_H

#include <sqlite3.h>

#endif /* MARKET_CSQLITE_SHIM_H */
