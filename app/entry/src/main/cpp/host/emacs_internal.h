/* Internal service operations shared by the Emacs host and its NAPI
   adapters.  Not part of the OHOS GUI ABI.  */
#ifndef OHOS_HOST_EMACS_INTERNAL_H
#define OHOS_HOST_EMACS_INTERNAL_H

struct ohos_emacs_api;

const struct ohos_emacs_api *EmacsLoadApi (const char *who);
int EmacsStartGuiThread ();
int EmacsStartDumpThread ();
void MaybeStartStackWatchdog (const char *cwd);

#endif
