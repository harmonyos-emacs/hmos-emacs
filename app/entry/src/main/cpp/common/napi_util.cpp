#include "napi_util.h"

std::string
NapiString (napi_env env, napi_value value)
{
  size_t len = 0;
  if (napi_get_value_string_utf8 (env, value, nullptr, 0, &len) != napi_ok
      || len == 0)
    return std::string ();
  std::string out (len + 1, '\0');
  size_t copied = 0;
  if (napi_get_value_string_utf8 (env, value, &out[0], len + 1, &copied)
      != napi_ok)
    return std::string ();
  out.resize (copied);
  return out;
}

int32_t
NapiInt (napi_env env, napi_value value, int32_t fallback)
{
  int32_t result = fallback;
  if (napi_get_value_int32 (env, value, &result) != napi_ok)
    return fallback;
  return result;
}

int64_t
NapiInt64 (napi_env env, napi_value value, int64_t fallback)
{
  int64_t result = fallback;
  if (napi_get_value_int64 (env, value, &result) != napi_ok)
    return fallback;
  return result;
}

double
NapiDouble (napi_env env, napi_value value, double fallback)
{
  double result = fallback;
  if (napi_get_value_double (env, value, &result) != napi_ok)
    return fallback;
  return result;
}

napi_value
ReturnInt (napi_env env, int32_t value)
{
  napi_value result = nullptr;
  napi_create_int32 (env, value, &result);
  return result;
}

napi_value
ReturnString (napi_env env, const std::string &value)
{
  napi_value result = nullptr;
  napi_create_string_utf8 (env, value.c_str (), value.size (), &result);
  return result;
}
