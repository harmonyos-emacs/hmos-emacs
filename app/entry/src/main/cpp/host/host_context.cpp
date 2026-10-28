#include "host_context.h"

HostContext &
HostContext::Get ()
{
  static HostContext context;
  return context;
}
