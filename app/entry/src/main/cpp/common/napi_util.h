/* Small helpers for the NAPI adapter layer: argument extraction and
   result construction without repeating napi_status boilerplate.  */
#ifndef OHOS_COMMON_NAPI_UTIL_H
#define OHOS_COMMON_NAPI_UTIL_H

#include <napi/native_api.h>

#include <cstdint>
#include <string>

std::string NapiString (napi_env env, napi_value value);
int32_t NapiInt (napi_env env, napi_value value, int32_t fallback);
int64_t NapiInt64 (napi_env env, napi_value value, int64_t fallback);
double NapiDouble (napi_env env, napi_value value, double fallback);

napi_value ReturnInt (napi_env env, int32_t value);
napi_value ReturnString (napi_env env, const std::string &value);

#endif
