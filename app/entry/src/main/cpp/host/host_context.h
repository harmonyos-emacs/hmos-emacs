/* Composition root: owns the process-lifetime host services.  */
#ifndef OHOS_HOST_CONTEXT_H
#define OHOS_HOST_CONTEXT_H

#include "emacs_host.h"
#include "ime.h"
#include "runtime_install.h"
#include "system_bridge.h"

struct HostContext
{
  EmacsHost emacs;
  RuntimeInstaller runtime;
  ImeService ime;
  SystemBridge system;

  static HostContext &Get ();

private:
  HostContext () = default;
};

#endif
