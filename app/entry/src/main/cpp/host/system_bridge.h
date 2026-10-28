/* Host chrome channel service: drains Emacs window commands, reports
   interactive results and tracks the ArkUI menu popup state.  */
#ifndef OHOS_HOST_SYSTEM_BRIDGE_H
#define OHOS_HOST_SYSTEM_BRIDGE_H

#include <string>

struct SystemBridge
{
  void ResolveMenu (int id, int index);
  void ResolveClipboard (int id, const std::string &text);

  void SetMenuOpen (bool open);
  int TakeMenuEsc ();
};

SystemBridge &HostSystem ();

#endif
