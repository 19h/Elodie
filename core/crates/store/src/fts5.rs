//! Registers the `elodie` tokenizer with FTS5.

use std::ffi::{c_char, c_int, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;

use elodie_text::{Mode, tokenize};
use rusqlite::{Connection, ffi};

/// The name used in `tokenize='elodie'`.
pub const TOKENIZER_NAME: &str = "elodie";

/// FTS5 needs a non-null tokenizer handle, but this tokenizer has no state.
/// The address of this byte stands in for one.
static TOKENIZER_HANDLE: u8 = 0;

unsafe extern "C" fn x_create(
    _user_data: *mut c_void,
    _args: *mut *const c_char,
    _arg_count: c_int,
    out: *mut *mut ffi::Fts5Tokenizer,
) -> c_int {
    // SAFETY: FTS5 passes a valid out-pointer.
    unsafe { *out = ptr::from_ref(&TOKENIZER_HANDLE).cast_mut().cast() };
    ffi::SQLITE_OK
}

unsafe extern "C" fn x_delete(_tokenizer: *mut ffi::Fts5Tokenizer) {}

unsafe extern "C" fn x_tokenize(
    _tokenizer: *mut ffi::Fts5Tokenizer,
    ctx: *mut c_void,
    flags: c_int,
    text: *const c_char,
    len: c_int,
    x_token: Option<
        unsafe extern "C" fn(*mut c_void, c_int, *const c_char, c_int, c_int, c_int) -> c_int,
    >,
) -> c_int {
    let Some(x_token) = x_token else {
        return ffi::SQLITE_ERROR;
    };
    let bytes: &[u8] = match usize::try_from(len) {
        // SAFETY: FTS5 guarantees `text` points to `len` readable bytes.
        Ok(len) if len > 0 && !text.is_null() => unsafe {
            std::slice::from_raw_parts(text.cast(), len)
        },
        _ => &[],
    };
    // Text comes from our own UTF-8 strings. Anything else has no tokens.
    let Ok(text) = std::str::from_utf8(bytes) else {
        return ffi::SQLITE_OK;
    };
    let mode = if flags & ffi::FTS5_TOKENIZE_PREFIX != 0 {
        Mode::Prefix
    } else if flags & ffi::FTS5_TOKENIZE_QUERY != 0 {
        Mode::Query
    } else {
        Mode::Document
    };

    let mut rc = ffi::SQLITE_OK;
    // A panic must not unwind into C.
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        tokenize(text, mode, |token| {
            let tflags = if token.colocated { ffi::FTS5_TOKEN_COLOCATED } else { 0 };
            let (Ok(token_len), Ok(start), Ok(end)) = (
                c_int::try_from(token.text.len()),
                c_int::try_from(token.start),
                c_int::try_from(token.end),
            ) else {
                rc = ffi::SQLITE_TOOBIG;
                return false;
            };
            // SAFETY: the pointer and length describe a live UTF-8 slice, and
            // `ctx` is the context FTS5 gave us for this call.
            rc = unsafe { x_token(ctx, tflags, token.text.as_ptr().cast(), token_len, start, end) };
            rc == ffi::SQLITE_OK
        });
    }));
    if outcome.is_err() {
        return ffi::SQLITE_ERROR;
    }
    rc
}

fn sqlite_error(rc: c_int, message: &str) -> rusqlite::Error {
    rusqlite::Error::SqliteFailure(ffi::Error::new(rc), Some(message.to_owned()))
}

/// Fetches the connection's FTS5 API through its documented pointer interface.
fn fts5_api(conn: &Connection) -> rusqlite::Result<*mut ffi::fts5_api> {
    // SAFETY: the handle is valid for the borrow of `conn`. The statement is
    // finalized before returning, and `api` outlives it.
    unsafe {
        let db = conn.handle();
        let mut stmt = ptr::null_mut();
        let rc = ffi::sqlite3_prepare_v2(db, c"SELECT fts5(?1)".as_ptr(), -1, &mut stmt, ptr::null_mut());
        if rc != ffi::SQLITE_OK {
            return Err(sqlite_error(rc, "couldn't prepare the FTS5 API query"));
        }
        let mut api: *mut ffi::fts5_api = ptr::null_mut();
        ffi::sqlite3_bind_pointer(
            stmt,
            1,
            ptr::from_mut(&mut api).cast(),
            c"fts5_api_ptr".as_ptr(),
            None,
        );
        ffi::sqlite3_step(stmt);
        let rc = ffi::sqlite3_finalize(stmt);
        if rc != ffi::SQLITE_OK || api.is_null() {
            return Err(sqlite_error(rc, "FTS5 API is unavailable"));
        }
        Ok(api)
    }
}

/// Registers the tokenizer. Registration is per connection.
pub fn register_tokenizer(conn: &Connection) -> rusqlite::Result<()> {
    let api = fts5_api(conn)?;
    let mut tokenizer = ffi::fts5_tokenizer {
        xCreate: Some(x_create),
        xDelete: Some(x_delete),
        xTokenize: Some(x_tokenize),
    };
    // SAFETY: `api` is valid for this connection, and FTS5 copies the tokenizer
    // struct during this call. The user data is unused.
    let rc = unsafe {
        let create = (*api)
            .xCreateTokenizer
            .ok_or_else(|| sqlite_error(ffi::SQLITE_ERROR, "FTS5 has no xCreateTokenizer"))?;
        create(api, c"elodie".as_ptr(), ptr::null_mut(), &mut tokenizer, None)
    };
    if rc != ffi::SQLITE_OK {
        return Err(sqlite_error(rc, "couldn't register the elodie tokenizer"));
    }
    Ok(())
}
