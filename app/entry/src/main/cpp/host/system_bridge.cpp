#include "system_bridge.h"

#include "gui_log.h"
#include "input.h"
#include "ohos_gui.h"
#include "host_context.h"

SystemBridge &
HostSystem ()
{
  return HostContext::Get ().system;
}

void
SystemBridge::ResolveMenu (int id, int index)
{
  LOGI ("menu result id=%{public}d index=%{public}d", id, index);
  ohosgui_host_menu_result (id, index);
}

void
SystemBridge::ResolveClipboard (int id, const std::string &text)
{
  LOGI ("clipboard result id=%{public}d len=%{public}zu", id, text.size ());
  ohosgui_host_request_result (id, 0, text.c_str ());
}

void
SystemBridge::SetMenuOpen (bool open)
{
  ohosgui::SetMenuOpen (open ? 1 : 0);
  LOGI ("menu open state=%{public}d", (int) open);
}

int
SystemBridge::TakeMenuEsc ()
{
  return ohosgui::TakeMenuEsc ();
}
