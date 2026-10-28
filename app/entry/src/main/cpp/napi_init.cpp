/*
 * Native back end for GNU Emacs on HarmonyOS.
 *
 * The Emacs core is built as libemacs.so and loaded into a forked
 * child process; the child gets a pty slave as its standard streams.
 * The parent (the HarmonyOS UI process) reads the pty master and
 * renders the escape sequences in the terminal view.
 */

#include <napi/native_api.h>
#include <hilog/log.h>

#include <cerrno>
#include <climits>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <dirent.h>
#include <dlfcn.h>
#include <link.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <zlib.h>
#include <ctime>

#undef LOG_TAG
#define LOG_TAG "emacs-hmos"
#define LOGI(...) OH_LOG_Print (LOG_APP, LOG_INFO, 0x0000, LOG_TAG, __VA_ARGS__)
#define LOGWLOG(...) OH_LOG_Print (LOG_APP, LOG_INFO, 0x0000, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print (LOG_APP, LOG_ERROR, 0x0000, LOG_TAG, __VA_ARGS__)

namespace {

bool MakeDirs (const std::string &path);

std::string g_utf8_pending;

size_t Utf8SeqLen (unsigned char c)
{
  if (c < 0x80)
    return 1;
  if ((c & 0xe0) == 0xc0)
    return 2;
  if ((c & 0xf0) == 0xe0)
    return 3;
  if ((c & 0xf8) == 0xf0)
    return 4;
  return 0;
}

/* Append raw bytes to the pending buffer and return the longest valid
   UTF-8 prefix, leaving an incomplete trailing sequence for next time.  */
std::string Utf8Decode (const char *data, size_t len)
{
  g_utf8_pending.append (data, len);
  if (g_utf8_pending.size () > (1u << 20))
    g_utf8_pending.erase (0, g_utf8_pending.size () - (1u << 16));

  std::string out;
  size_t i = 0;
  while (i < g_utf8_pending.size ())
    {
      unsigned char c = (unsigned char) g_utf8_pending[i];
      size_t n = Utf8SeqLen (c);
      if (n == 0)
	{
	  out.push_back ('?');
	  i += 1;
	  continue;
	}
      if (i + n > g_utf8_pending.size ())
	break;
      bool ok = true;
      for (size_t k = 1; k < n; k++)
	if (((unsigned char) g_utf8_pending[i + k] & 0xc0) != 0x80)
	  {
	    ok = false;
	    break;
	  }
      if (!ok)
	{
	  out.push_back ('?');
	  i += 1;
	  continue;
	}
      out.append (g_utf8_pending, i, n);
      i += n;
    }
  g_utf8_pending.erase (0, i);
  return out;
}
void TouchElc (const std::string &dir);

int g_master = -1;
int g_slave = -1;
int g_logfile = -1;
pid_t g_child = -1;
bool g_running = false;
int g_exit_status = -1;
pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

void SplitLines (const std::string &text, std::vector<std::string> &out)
{
  size_t pos = 0;
  while (pos < text.size ())
    {
      size_t nl = text.find ('\n', pos);
      if (nl == std::string::npos)
	nl = text.size ();
      out.push_back (text.substr (pos, nl - pos));
      pos = nl + 1;
    }
}

void SetWindowSize (int cols, int rows)
{
  if (g_slave < 0 && g_master < 0)
    {
      LOGWLOG ("resize skipped: no tty");
      return;
    }
  struct winsize ws = { (unsigned short) rows, (unsigned short) cols, 0, 0 };
  int rc = -1, err = 0;
  if (g_slave >= 0)
    {
      errno = 0;
      rc = ioctl (g_slave, TIOCSWINSZ, &ws);
      err = errno;
    }
  int rc2 = -1, err2 = 0;
  if (rc != 0 && g_master >= 0)
    {
      errno = 0;
      rc2 = ioctl (g_master, TIOCSWINSZ, &ws);
      err2 = errno;
    }
  struct winsize now = { 0, 0, 0, 0 };
  if (g_slave >= 0)
    ioctl (g_slave, TIOCGWINSZ, &now);
  if (g_child > 0)
    kill (g_child, SIGWINCH);
  LOGWLOG ("resize %{public}s", (std::to_string (cols) + "x" + std::to_string (rows)
    + " slave=" + std::to_string (g_slave) + " master=" + std::to_string (g_master)
    + " rc=" + std::to_string (rc) + " errno=" + std::to_string (err)
    + " rc2=" + std::to_string (rc2) + " errno2=" + std::to_string (err2)
    + " now=" + std::to_string (now.ws_col) + "x" + std::to_string (now.ws_row)).c_str ());
}

bool ChildAlive ()
{
  if (g_child <= 0)
    return false;
  int status = 0;
  pid_t w = waitpid (g_child, &status, WNOHANG);
  if (w == g_child)
    {
      g_running = false;
      g_exit_status = WIFEXITED (status) ? WEXITSTATUS (status)
	: 128 + (WIFSIGNALED (status) ? WTERMSIG (status) : 0);
      return false;
    }
  return true;
}

} // namespace

static napi_value StartEmacs (napi_env env, napi_callback_info info)
{
  size_t argc = 5;
  napi_value argv[5] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);

  char args_text[4096] = { 0 };
  char env_text[4096] = { 0 };
  char cwd[1024] = { 0 };
  int32_t cols = 120, rows = 40;
  if (argc > 3)
    napi_get_value_int32 (env, argv[3], &cols);
  if (argc > 4)
    napi_get_value_int32 (env, argv[4], &rows);
  if (argc > 0)
    {
      size_t len = 0;
      napi_get_value_string_utf8 (env, argv[0], args_text, sizeof args_text, &len);
    }
  if (argc > 1)
    {
      size_t len = 0;
      napi_get_value_string_utf8 (env, argv[1], env_text, sizeof env_text, &len);
    }
  if (argc > 2)
    {
      size_t len = 0;
      napi_get_value_string_utf8 (env, argv[2], cwd, sizeof cwd, &len);
    }

  pthread_mutex_lock (&g_lock);
  if (g_running)
    {
      pthread_mutex_unlock (&g_lock);
      napi_value r;
      napi_create_int32 (env, -2, &r);
      return r;
    }
  if (cwd[0])
    {
      std::string base = cwd;
      MakeDirs (base + "/home/.emacs.d");
      MakeDirs (base + "/tmp");
      if (access ((base + "/.elc-touched").c_str (), F_OK) != 0)
	{
	  TouchElc (base + "/lisp");
	  int mfd = open ((base + "/.elc-touched").c_str (),
			  O_WRONLY | O_CREAT | O_TRUNC, 0644);
	  if (mfd >= 0)
	    close (mfd);
	}
    }

  int fd = posix_openpt (O_RDWR | O_NOCTTY);
  if (fd < 0)
    {
      LOGE ("posix_openpt failed: %{public}s", strerror (errno));
      pthread_mutex_unlock (&g_lock);
      napi_value r;
      napi_create_int32 (env, -1, &r);
      return r;
    }
  if (grantpt (fd) < 0 || unlockpt (fd) < 0)
    {
      LOGE ("grantpt/unlockpt failed: %{public}s", strerror (errno));
      close (fd);
      pthread_mutex_unlock (&g_lock);
      napi_value r;
      napi_create_int32 (env, -1, &r);
      return r;
    }
  const char *name = ptsname (fd);
  int sfd = name ? open (name, O_RDWR | O_NOCTTY) : -1;
  if (sfd < 0)
    {
      LOGE ("open pty slave failed: %{public}s", strerror (errno));
      close (fd);
      pthread_mutex_unlock (&g_lock);
      napi_value r;
      napi_create_int32 (env, -1, &r);
      return r;
    }
  {
    struct winsize ws0 = { (unsigned short) rows, (unsigned short) cols, 0, 0 };
    ioctl (sfd, TIOCSWINSZ, &ws0);
  }

  pid_t pid = fork ();
  if (pid < 0)
    {
      LOGE ("fork failed: %{public}s", strerror (errno));
      close (sfd);
      close (fd);
      pthread_mutex_unlock (&g_lock);
      napi_value r;
      napi_create_int32 (env, -1, &r);
      return r;
    }
  if (pid == 0)
    {
      close (fd);
      setsid ();
      ioctl (sfd, TIOCSCTTY, 0);
      dup2 (sfd, 0);
      dup2 (sfd, 1);
      dup2 (sfd, 2);
      if (sfd > 2)
	close (sfd);

      std::vector<std::string> args;
      SplitLines (args_text, args);
      std::vector<std::string> envs;
      SplitLines (env_text, envs);
      for (auto &kv : envs)
	{
	  size_t eq = kv.find ('=');
	  if (eq != std::string::npos)
	    setenv (kv.substr (0, eq).c_str (), kv.substr (eq + 1).c_str (), 1);
	}
      setenv ("TERM", "xterm-256color", 1);
      if (cwd[0])
	{
	  std::string errpath = std::string (cwd) + "/emacs-stderr.txt";
	  int efd = open (errpath.c_str (), O_WRONLY | O_CREAT | O_TRUNC, 0644);
	  if (efd >= 0)
	    {
	      dup2 (efd, 2);
	      if (efd > 2)
		close (efd);
	    }
	}
      if (!cwd[0])
	chdir ("/");
      else
	chdir (cwd);
      LOGI ("child: loading libemacs.so (HOME=%{public}s exists=%{public}d)", getenv ("HOME") ? getenv ("HOME") : "(nil)", getenv ("HOME") ? (int) (access (getenv ("HOME"), F_OK) == 0) : -1);

      void *h = dlopen ("libemacs.so", RTLD_NOW | RTLD_LOCAL);
      if (!h)
	{
	  dprintf (2, "dlopen libemacs.so failed: %s\n", dlerror ());
	  _exit (126);
	}
      int (*emacs_main) (int, char **)
	= (int (*) (int, char **)) dlsym (h, "main");
      {
	Dl_info info;
	if (emacs_main && dladdr ((void *) emacs_main, &info))
	  LOGI ("libemacs.so base=%{public}p", info.dli_fbase);
      }
      if (!emacs_main)
	{
	  dprintf (2, "dlsym main failed: %s\n", dlerror ());
	  _exit (126);
	}

      std::vector<char *> c_argv;
      c_argv.push_back ((char *) "emacs");
      LOGI ("child argc=%{public}d", (int) args.size ());
      for (auto &a : args)
	LOGI ("arg: [%{public}s]", a.c_str ());
      for (auto &a : args)
	c_argv.push_back ((char *) a.c_str ());
      c_argv.push_back (nullptr);
      LOGI ("EMACSLOADPATH=%{public}s", getenv ("EMACSLOADPATH") ? getenv ("EMACSLOADPATH") : "(unset)");
      LOGI ("cwd=%{public}s", cwd);
      LOGI ("calling emacs main now");
      int rc = emacs_main ((int) c_argv.size () - 1, c_argv.data ());
      LOGI ("emacs main returned %{public}d", rc);
      _exit (rc);
    }

  g_slave = sfd;
  SetWindowSize (cols, rows);
  fcntl (fd, F_SETFL, O_NONBLOCK);
  if (cwd[0])
    {
      std::string logpath = std::string (cwd) + "/emacs-log.txt";
      if (g_logfile >= 0)
	close (g_logfile);
      g_logfile = open (logpath.c_str (), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    }
  g_master = fd;
  g_child = pid;
  g_running = true;
  g_exit_status = -1;
  pthread_mutex_unlock (&g_lock);

  napi_value r;
  napi_create_int32 (env, 0, &r);
  return r;
}

static napi_value ReadOutput (napi_env env, napi_callback_info info)
{
  pthread_mutex_lock (&g_lock);
  std::string out;
  if (g_master >= 0)
    {
      char buf[8192];
      for (;;)
	{
	  ssize_t n = read (g_master, buf, sizeof buf);
	  if (n > 0)
	    {
	      out.append (buf, n);
	      if (g_logfile >= 0)
		{
		  ssize_t off = 0;
		  while (off < n)
		    {
		      ssize_t w = write (g_logfile, buf + off, n - off);
		      if (w <= 0)
			break;
		      off += w;
		    }
		}
	    }
	  else
	    break;
	}
      ChildAlive ();
    }
  pthread_mutex_unlock (&g_lock);

  napi_value result;
  napi_create_string_utf8 (env, out.data (), out.size (), &result);
  return result;
}

static napi_value WriteInput (napi_env env, napi_callback_info info)
{
  size_t argc = 1;
  napi_value argv[1] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);

  char text[4096] = { 0 };
  size_t len = 0;
  if (argc > 0)
    napi_get_value_string_utf8 (env, argv[0], text, sizeof text - 1, &len);

  pthread_mutex_lock (&g_lock);
  if (g_master >= 0 && g_running && len > 0)
    {
      size_t off = 0;
      int guard = 0;
      while (off < len && guard++ < 1000)
	{
	  ssize_t n = write (g_master, text + off, len - off);
	  if (n > 0)
	    off += n;
	  else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
	    {
	      struct pollfd pfd = { g_master, POLLOUT, 0 };
	      poll (&pfd, 1, 50);
	    }
	  else
	    break;
	}
    }
  pthread_mutex_unlock (&g_lock);

  napi_value r;
  napi_create_int32 (env, 0, &r);
  return r;
}

static napi_value ResizeTerm (napi_env env, napi_callback_info info)
{
  size_t argc = 2;
  napi_value argv[2] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  int32_t cols = 120, rows = 40;
  if (argc > 0)
    napi_get_value_int32 (env, argv[0], &cols);
  if (argc > 1)
    napi_get_value_int32 (env, argv[1], &rows);
  SetWindowSize (cols, rows);
  napi_value r;
  napi_create_int32 (env, 0, &r);
  return r;
}

static napi_value StopEmacs (napi_env env, napi_callback_info info)
{
  pthread_mutex_lock (&g_lock);
  if (g_child > 0 && g_running)
    {
      kill (g_child, SIGKILL);
      waitpid (g_child, nullptr, 0);
    }
  if (g_master >= 0)
    {
      close (g_master);
      g_master = -1;
    }
  if (g_slave >= 0)
    {
      close (g_slave);
      g_slave = -1;
    }
  g_child = -1;
  g_running = false;
  pthread_mutex_unlock (&g_lock);
  napi_value r;
  napi_create_int32 (env, 0, &r);
  return r;
}

static napi_value State (napi_env env, napi_callback_info info)
{
  pthread_mutex_lock (&g_lock);
  if (g_running)
    ChildAlive ();
  std::string json = "{\"running\":";
  json += g_running ? "true" : "false";
  json += ",\"exit\":" + std::to_string (g_exit_status) + "}";
  pthread_mutex_unlock (&g_lock);

  napi_value r;
  napi_create_string_utf8 (env, json.c_str (), json.size (), &r);
  return r;
}


namespace {

struct InstallStatus
{
  bool running;
  bool done;
  std::string error;
  long long files;
  long long bytes;
  long long total;
};

InstallStatus g_install = { false, false, "", 0, 0, 0 };
pthread_t g_install_tid;
bool g_install_started = false;
int g_install_fd = -1;
long long g_install_offset = 0;
long long g_install_length = 0;
std::string g_install_tar;
std::string g_install_dir;

std::string TrimField (const char *p, size_t n)
{
  size_t len = 0;
  while (len < n && p[len])
    len++;
  return std::string (p, len);
}

long long ParseOctal (const char *p, size_t n)
{
  if (n && (p[0] & 0x80))
    {
      long long v = p[0] & 0x7f;
      for (size_t i = 1; i < n; i++)
	v = (v << 8) | (unsigned char) p[i];
      return v;
    }
  long long v = 0;
  for (size_t i = 0; i < n; i++)
    {
      if (p[i] < '0' || p[i] > '7')
	continue;
      v = v * 8 + (p[i] - '0');
    }
  return v;
}

std::string JoinPath (const std::string &a, const std::string &b)
{
  if (a.empty ())
    return b;
  if (a.back () == '/')
    return a + b;
  return a + "/" + b;
}

bool MakeDirs (const std::string &path)
{
  std::string cur;
  size_t i = 0;
  if (!path.empty () && path[0] == '/')
    {
      cur = "/";
      i = 1;
    }
  while (i <= path.size ())
    {
      size_t slash = path.find ('/', i);
      if (slash == std::string::npos)
	slash = path.size ();
      if (slash > i)
	{
	  cur = JoinPath (cur, path.substr (i, slash - i));
	  if (mkdir (cur.c_str (), 0755) < 0 && errno != EEXIST)
	    return false;
	}
      i = slash + 1;
      if (i > path.size ())
	break;
    }
  return true;
}

std::string ParentDir (const std::string &path)
{
  size_t slash = path.rfind ('/');
  if (slash == std::string::npos)
    return "";
  return path.substr (0, slash);
}

bool SafeName (const std::string &name)
{
  if (name.empty () || name[0] == '/')
    return false;
  if (name.find ("..") != std::string::npos)
    return false;
  return true;
}

/* Read exactly N bytes from a gzFile, unless at end.  */
ssize_t ReadAll (gzFile gz, char *buf, ssize_t want)
{
  ssize_t got = 0;
  while (got < want)
    {
      int n = gzread (gz, buf + got, (unsigned) (want - got));
      if (n <= 0)
	break;
      got += n;
    }
  return got;
}

int ExtractTarGz (const std::string &src, const std::string &dest,
		  std::string &err)
{
  gzFile gz = gzopen (src.c_str (), "rb");
  if (!gz)
    {
      err = std::string ("gzopen: ") + strerror (errno);
      return -1;
    }

  char header[512];
  std::string longname;
  std::string paxpath;
  char buf[65536];
  int rc = 0;

  while (true)
    {
      ssize_t n = ReadAll (gz, header, 512);
      if (n != 512)
	break;
      bool zero = true;
      for (int i = 0; i < 512; i++)
	if (header[i])
	  {
	    zero = false;
	    break;
	  }
      if (zero)
	break;

      std::string name = TrimField (header, 100);
      std::string prefix = TrimField (header + 345, 155);
      if (!prefix.empty ())
	name = prefix + "/" + name;
      long long size = ParseOctal (header + 124, 12);
      char type = header[156];
      std::string linkname = TrimField (header + 157, 100);

      long long padded = (size + 511) & ~511LL;

      if (type == 'L')
	{
	  longname.resize (size);
	  ReadAll (gz, &longname[0], size);
	  gzseek (gz, padded - size, SEEK_CUR);
	  continue;
	}
      if (type == 'x')
	{
	  std::string data;
	  data.resize (size);
	  ReadAll (gz, &data[0], size);
	  gzseek (gz, padded - size, SEEK_CUR);
	  size_t pos = 0;
	  while (pos < data.size ())
	    {
	      size_t sp = data.find (' ', pos);
	      if (sp == std::string::npos)
		break;
	      long long reclen = atoll (data.c_str () + pos);
	      if (reclen <= 0 || pos + reclen > data.size ())
		break;
	      std::string rec = data.substr (sp + 1, pos + reclen - sp - 2);
	      if (rec.compare (0, 5, "path=") == 0)
		paxpath = rec.substr (5);
	      pos += reclen;
	    }
	  continue;
	}

      if (!longname.empty ())
	{
	  name = longname;
	  longname.clear ();
	}
      if (!paxpath.empty ())
	{
	  name = paxpath;
	  paxpath.clear ();
	}

      if (!SafeName (name))
	{
	  gzseek (gz, padded, SEEK_CUR);
	  continue;
	}

      std::string outpath = JoinPath (dest, name);

      if (type == '5')
	{
	  MakeDirs (outpath);
	  gzseek (gz, padded, SEEK_CUR);
	  continue;
	}
      if (type == '2')
	{
	  if (!ParentDir (outpath).empty ())
	    MakeDirs (ParentDir (outpath));
	  symlink (linkname.c_str (), outpath.c_str ());
	  gzseek (gz, padded, SEEK_CUR);
	  continue;
	}
      if (type != '0' && type != 0)
	{
	  gzseek (gz, padded, SEEK_CUR);
	  continue;
	}

      if (!ParentDir (outpath).empty () && !MakeDirs (ParentDir (outpath)))
	{
	  err = std::string ("mkdir: ") + strerror (errno);
	  rc = -1;
	  break;
	}

      long long mode = ParseOctal (header + 100, 8) & 0777;
      int fd = open (outpath.c_str (), O_WRONLY | O_CREAT | O_TRUNC, mode ? mode : 0644);
      if (fd < 0)
	{
	  err = std::string ("open ") + outpath + ": " + strerror (errno);
	  rc = -1;
	  break;
	}

      long long left = size;
      while (left > 0)
	{
	  int want = (int) (left < (long long) sizeof buf ? left : (long long) sizeof buf);
	  int got = gzread (gz, buf, want);
	  if (got <= 0)
	    break;
	  if (write (fd, buf, got) != got)
	    {
	      err = std::string ("write ") + outpath + ": " + strerror (errno);
	      close (fd);
	      rc = -1;
	      break;
	    }
	  left -= got;
	  g_install.bytes += got;
	}
      close (fd);
      if (rc != 0)
	break;
      if (left > 0)
	{
	  err = std::string ("truncated ") + outpath;
	  rc = -1;
	  break;
	}
      long long pad = padded - size;
      while (pad > 0)
	{
	  int want = (int) (pad < (long long) sizeof buf ? pad : (long long) sizeof buf);
	  int got = gzread (gz, buf, want);
	  if (got <= 0)
	    break;
	  pad -= got;
	}
      g_install.files++;
    }

  gzclose (gz);
  return rc;
}


void TouchElc (const std::string &dir)
{
  DIR *d = opendir (dir.c_str ());
  if (!d)
    return;
  struct dirent *e;
  while ((e = readdir (d)) != nullptr)
    {
      if (!strcmp (e->d_name, ".") || !strcmp (e->d_name, ".."))
	continue;
      std::string p = dir + "/" + e->d_name;
      struct stat st;
      if (lstat (p.c_str (), &st) != 0)
	continue;
      if (S_ISDIR (st.st_mode))
	TouchElc (p);
      else if (S_ISREG (st.st_mode) && p.size () > 4
	       && p.compare (p.size () - 4, 4, ".elc") == 0)
	{
	  struct timespec times[2];
	  times[0].tv_sec = 0;
	  times[0].tv_nsec = UTIME_NOW;
	  times[1].tv_sec = 0;
	  times[1].tv_nsec = UTIME_NOW;
	  utimensat (AT_FDCWD, p.c_str (), times, 0);
	}
    }
  closedir (d);
}

void *InstallThread (void *)
{
  std::string err;

  /* Copy the archive out of the HAP raw file descriptor.  */
  int out = open (g_install_tar.c_str (), O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (out < 0)
    {
      pthread_mutex_lock (&g_lock);
      g_install.error = std::string ("open tar: ") + strerror (errno);
      g_install.running = false;
      g_install.done = true;
      pthread_mutex_unlock (&g_lock);
      return nullptr;
    }

  long long done = 0;
  char buf[65536];
  while (done < g_install_length)
    {
      long long left = g_install_length - done;
      int want = (int) (left < (long long) sizeof buf ? left : (long long) sizeof buf);
      ssize_t n = pread (g_install_fd, buf, want, g_install_offset + done);
      if (n <= 0)
	break;
      if (write (out, buf, n) != n)
	break;
      done += n;
      pthread_mutex_lock (&g_lock);
      g_install.bytes = done;
      pthread_mutex_unlock (&g_lock);
    }
  close (out);
  if (g_install_fd >= 0)
    close (g_install_fd);
  g_install_fd = -1;

  pthread_mutex_lock (&g_lock);
  g_install.bytes = 0;
  g_install.total = g_install_length;
  pthread_mutex_unlock (&g_lock);

  if (done != g_install_length)
    err = "short read from raw file";
  else
    {
      ExtractTarGz (g_install_tar, g_install_dir, err);
      if (err.empty ())
	{
	  MakeDirs (g_install_dir + "/home/.emacs.d");
	  MakeDirs (g_install_dir + "/tmp");
	  TouchElc (g_install_dir + "/lisp");
	}
    }

  pthread_mutex_lock (&g_lock);
  g_install.error = err;
  g_install.running = false;
  g_install.done = true;
  pthread_mutex_unlock (&g_lock);
  return nullptr;
}

} // namespace

static napi_value StartInstallRuntime (napi_env env, napi_callback_info info)
{
  size_t argc = 5;
  napi_value argv[5] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);

  int32_t fd = -1;
  int64_t offset = 0, length = 0;
  char tar[1024] = { 0 };
  char dir[1024] = { 0 };
  if (argc > 0)
    napi_get_value_int32 (env, argv[0], &fd);
  if (argc > 1)
    napi_get_value_int64 (env, argv[1], &offset);
  if (argc > 2)
    napi_get_value_int64 (env, argv[2], &length);
  if (argc > 3)
    {
      size_t len = 0;
      napi_get_value_string_utf8 (env, argv[3], tar, sizeof tar, &len);
    }
  if (argc > 4)
    {
      size_t len = 0;
      napi_get_value_string_utf8 (env, argv[4], dir, sizeof dir, &len);
    }

  pthread_mutex_lock (&g_lock);
  if (g_install_started && g_install.running)
    {
      pthread_mutex_unlock (&g_lock);
      napi_value r;
      napi_create_int32 (env, -2, &r);
      return r;
    }
  g_install_started = true;
  g_install = { true, false, "", 0, 0, 0 };
  g_install_fd = dup (fd);
  g_install_offset = offset;
  g_install_length = length;
  g_install_tar = tar;
  g_install_dir = dir;
  pthread_mutex_unlock (&g_lock);

  MakeDirs (dir);
  pthread_create (&g_install_tid, nullptr, InstallThread, nullptr);
  pthread_detach (g_install_tid);

  napi_value r;
  napi_create_int32 (env, 0, &r);
  return r;
}

static napi_value InstallState (napi_env env, napi_callback_info info)
{
  pthread_mutex_lock (&g_lock);
  std::string json = "{\"running\":";
  json += g_install.running ? "true" : "false";
  json += ",\"done\":";
  json += g_install.done ? "true" : "false";
  json += ",\"files\":" + std::to_string (g_install.files);
  json += ",\"bytes\":" + std::to_string (g_install.bytes);
  json += ",\"error\":\"" + g_install.error + "\"}";
  pthread_mutex_unlock (&g_lock);

  napi_value r;
  napi_create_string_utf8 (env, json.c_str (), json.size (), &r);
  return r;
}

static napi_value RuntimeReady (napi_env env, napi_callback_info info)
{
  size_t argc = 1;
  napi_value argv[1] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  char path[1024] = { 0 };
  if (argc > 0)
    {
      size_t len = 0;
      napi_get_value_string_utf8 (env, argv[0], path, sizeof path, &len);
    }
  napi_value r;
  napi_create_int32 (env, access (path, R_OK) == 0 ? 1 : 0, &r);
  return r;
}


static napi_value BuildId (napi_env env, napi_callback_info info)
{
  static const char id[] = __DATE__ " " __TIME__;
  napi_value r;
  napi_create_string_utf8 (env, id, NAPI_AUTO_LENGTH, &r);
  return r;
}

static napi_value FileRead (napi_env env, napi_callback_info info)
{
  size_t argc = 1;
  napi_value argv[1] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  char path[1024] = { 0 };
  if (argc > 0)
    {
      size_t len = 0;
      napi_get_value_string_utf8 (env, argv[0], path, sizeof path, &len);
    }
  int fd = open (path, O_RDONLY);
  if (fd < 0)
    {
      napi_value r;
      napi_create_string_utf8 (env, "", 0, &r);
      return r;
    }
  std::string data;
  char buf[4096];
  ssize_t n;
  while ((n = read (fd, buf, sizeof buf)) > 0)
    data.append (buf, n);
  close (fd);
  napi_value r;
  napi_create_string_utf8 (env, data.data (), data.size (), &r);
  return r;
}

static napi_value FileWrite (napi_env env, napi_callback_info info)
{
  size_t argc = 2;
  napi_value argv[2] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  char path[1024] = { 0 };
  size_t textlen = 0;
  if (argc > 0)
    {
      size_t len = 0;
      napi_get_value_string_utf8 (env, argv[0], path, sizeof path, &len);
    }
  char *text = nullptr;
  if (argc > 1)
    napi_get_value_string_utf8 (env, argv[1], nullptr, 0, &textlen);
  text = (char *) malloc (textlen + 1);
  if (!text)
    {
      napi_value r;
      napi_create_int32 (env, -1, &r);
      return r;
    }
  if (argc > 1)
    napi_get_value_string_utf8 (env, argv[1], text, textlen + 1, &textlen);
  int fd = open (path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0)
    {
      napi_value r;
      napi_create_int32 (env, -1, &r);
      return r;
    }
  ssize_t w = write (fd, text, textlen);
  close (fd);
  free (text);
  napi_value r;
  napi_create_int32 (env, w == (ssize_t) textlen ? 0 : -1, &r);
  return r;
}

static napi_value FileRemove (napi_env env, napi_callback_info info)
{
  size_t argc = 1;
  napi_value argv[1] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  char path[1024] = { 0 };
  if (argc > 0)
    {
      size_t len = 0;
      napi_get_value_string_utf8 (env, argv[0], path, sizeof path, &len);
    }
  napi_value r;
  napi_create_int32 (env, unlink (path) == 0 ? 0 : -1, &r);
  return r;
}


static napi_value LibemacsVersion (napi_env env, napi_callback_info info)
{
  std::string version;
  Dl_info dl;
  if (dladdr ((void *) LibemacsVersion, &dl) && dl.dli_fname)
    {
      std::string dir = dl.dli_fname;
      size_t slash = dir.rfind ('/');
      if (slash != std::string::npos)
	dir = dir.substr (0, slash);
      std::string lib = dir + "/libemacs.so";
      struct stat st;
      if (stat (lib.c_str (), &st) == 0)
	version = std::to_string ((long long) st.st_size) + "-"
	  + std::to_string ((long long) st.st_mtime);
    }
  napi_value r;
  napi_create_string_utf8 (env, version.c_str (), version.size (), &r);
  return r;
}

static napi_value Init (napi_env env, napi_value exports)
{
  napi_property_descriptor desc[] = {
    { "startEmacs", nullptr, StartEmacs, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "readOutput", nullptr, ReadOutput, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "writeInput", nullptr, WriteInput, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "resizeTerm", nullptr, ResizeTerm, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "stopEmacs", nullptr, StopEmacs, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "state", nullptr, State, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "startInstallRuntime", nullptr, StartInstallRuntime, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "installState", nullptr, InstallState, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "runtimeReady", nullptr, RuntimeReady, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "buildId", nullptr, BuildId, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "libemacsVersion", nullptr, LibemacsVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "fileRead", nullptr, FileRead, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "fileWrite", nullptr, FileWrite, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "fileRemove", nullptr, FileRemove, nullptr, nullptr, nullptr, napi_default, nullptr },
  };
  napi_define_properties (env, exports, sizeof desc / sizeof desc[0], desc);
  return exports;
}

static napi_module emacsModule = {
  1,
  0,
  nullptr,
  Init,
  "entry",
  nullptr,
};

extern "C" __attribute__((constructor)) void RegisterEmacsModule (void)
{
  napi_module_register (&emacsModule);
}
