;;; runner.el --- one-package compatibility probe for emacs-hmos  -*- lexical-binding: t; -*-

;; Invoked by the HarmonyOS app's package-index controller as:
;;   emacs --dump-file=... -batch -Q -l runner.el PKG BENCH-DIR RESULT-FILE
;;
;; It installs PKG into BENCH-DIR/elpa, byte-compiles its top-level
;; libraries, loads the main library, and writes a small JSON record.
;; Everything is best-effort: a failure in one probe must still produce
;; a result file so the controller can move on.

(require 'files)
(require 'package)
(require 'bytecomp)
(require 'json)
(require 'seq)
(require 'executable)

(defvar bench-pkg (intern (or (nth 0 command-line-args-left) "unknown")))
(defvar bench-dir (or (nth 1 command-line-args-left)
                      (expand-file-name "package-index" (getenv "HOME"))))
(defvar bench-result (or (nth 2 command-line-args-left)
                         (expand-file-name (format "results/%s.json" bench-pkg) bench-dir)))
(defvar bench-start (float-time))
(defvar bench-notes nil)
(defvar bench-refresh-error nil)

(setq user-emacs-directory (expand-file-name "home/.emacs.d/" bench-dir))
(setq package-quickstart nil)
(setq package-quickstart-file (expand-file-name "package-quickstart.elc" user-emacs-directory))
(setq package-native-compile nil)
(make-directory user-emacs-directory t)
(make-directory (expand-file-name "tmp/" bench-dir) t)
(make-directory (expand-file-name "results/" bench-dir) t)
(setq gnutls-trustfiles
      (list (expand-file-name "../etc/ssl/ca-bundle.crt" bench-dir)))

(defun bench-note (fmt &rest args)
  (push (apply #'format fmt args) bench-notes))

(defun bench-write (path text)
  (condition-case err
      (progn
        (make-directory (file-name-directory path) t)
        (with-temp-buffer
          (insert text)
          (write-region (point-min) (point-max) path nil 'silent))
        t)
    (error
     (message "bench-write %s: %s" path (error-message-string err))
     nil)))

(defun bench-json (data)
  (condition-case err
      (json-encode data)
    (error (format "{\"package\":%S,\"fatal_error\":%S}"
                   (symbol-name bench-pkg) (error-message-string err)))))

(defun bench-archive-setup ()
  (setq package-user-dir (expand-file-name "elpa/" bench-dir))
  (make-directory package-user-dir t)
  (setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                           ("melpa" . "https://melpa.org/packages/")))
  (setq package-check-signature nil)
  (setq package-native-compile nil)
  (setq package-archive-priorities nil)
  (package-initialize t)
  (let* ((marker (expand-file-name "archives-ok" bench-dir))
         (gnu (expand-file-name "archives/gnu/archive-contents" package-user-dir))
         (melpa (expand-file-name "archives/melpa/archive-contents" package-user-dir)))
    (bench-note "bench-dir=%s user-dir=%s gnu=%S melpa=%S archives=%S"
                bench-dir package-user-dir (file-exists-p gnu) (file-exists-p melpa)
                (length package-archive-contents))
    (unless (and (file-exists-p marker) (file-exists-p gnu))
      (condition-case err
          (package-refresh-contents)
        (error
         (setq bench-refresh-error (error-message-string err))
         (bench-note "archive refresh: %s" bench-refresh-error)))
      (bench-write marker (format "refresh-error=%S gnu=%S melpa=%S\n"
                                  bench-refresh-error (file-exists-p gnu)
                                  (file-exists-p melpa))))))

(defun bench-package-desc ()
  (car (cdr (assq bench-pkg package-alist))))

(defun bench-local-tar ()
  (let ((dir (expand-file-name "local-packages/" bench-dir)))
    (and (file-directory-p dir)
         (car (directory-files dir t
                               (concat "^" (regexp-quote (symbol-name bench-pkg))
                                       ".*\\.tar\\'"))))))

(defun bench-install ()
  (let ((beg (float-time)) err builtin)
    (condition-case e
        (progn
          (setq builtin (package-installed-p bench-pkg))
          (unless builtin
            (let ((tar (bench-local-tar)))
              (if tar
                  (progn
                    (bench-note "local tar: %s" tar)
                    (package-install-file tar))
                (package-install bench-pkg)))))
      (error (setq err (error-message-string e))))
    (setq builtin (or builtin (package-installed-p bench-pkg)))
    (list (cons 'status (if (and err (not builtin)) "failed" "ok"))
          (cons 'already_installed (if builtin t :json-false))
          (cons 'seconds (round (- (float-time) beg)))
          (cons 'error (or err json-null)))))

(defun bench-source-files (dir)
  (seq-filter
   (lambda (file)
     (let ((name (file-name-nondirectory file)))
       (and (string-suffix-p ".el" name)
            (not (string-match-p "-pkg\\.el\\'" name))
            (not (string-match-p "-autoloads\\.el\\'" name))
            (not (string-match-p "-tests?\\.el\\'" name)))))
   (directory-files dir t "\\.el\\'")))

(defun bench-compile (dir)
  (if (not dir)
      (list (cons 'status "builtin")
            (cons 'files 0) (cons 'compiled 0)
            (cons 'warnings 0) (cons 'warning_samples [])
            (cons 'errors []) (cons 'error_samples [])
            (cons 'seconds 0))
    (let ((files (bench-source-files dir))
          (warnings nil)
          (errors nil)
          (compiled 0)
          (beg (float-time)))
      (dolist (file files)
        (let ((byte-compile-log-warning-function
               (lambda (string _position _fill level)
                 (push (format "%s: %s" (or level "warning") string) warnings))))
          (condition-case e
              (progn
                (byte-compile-file file)
                (setq compiled (1+ compiled)))
            (error
             (push (cons (file-name-nondirectory file)
                         (error-message-string e))
                   errors)))))
      (list (cons 'status (cond ((null files) "no-source")
                                (errors "failed")
                                (warnings "warnings")
                                (t "ok")))
            (cons 'files (length files))
            (cons 'compiled compiled)
            (cons 'warnings (length warnings))
            (cons 'warning_samples (vconcat (seq-take (nreverse warnings) 8)))
            (cons 'errors (vconcat (mapcar (lambda (x) (cons 'file (car x)))
                                           (nreverse errors))))
            (cons 'error_samples (vconcat (mapcar (lambda (x) (cons 'error (cdr x)))
                                                  (nreverse errors))))
            (cons 'seconds (round (- (float-time) beg)))))))

(defun bench-main-file (dir)
  (or (and dir (let ((named (expand-file-name (concat (symbol-name bench-pkg) ".el") dir)))
                 (and (file-exists-p named) named)))
      (locate-library (symbol-name bench-pkg))
      (and dir (car (bench-source-files dir)))))

(defun bench-load (dir)
  (let ((main (bench-main-file dir))
        (beg (float-time))
        err feature)
    (if (not main)
        (list (cons 'status "no-source")
              (cons 'file json-null)
              (cons 'seconds 0)
              (cons 'error "no top-level .el file"))
      (condition-case e
          (progn
            (load (file-name-sans-extension main) nil nil)
            (setq feature (featurep bench-pkg)))
        (quit (setq err "quit"))
        (error (setq err (error-message-string e))))
      (list (cons 'status (if err "failed" "ok"))
            (cons 'file (file-name-nondirectory main))
            (cons 'feature (if feature t :json-false))
            (cons 'seconds (round (- (float-time) beg)))
            (cons 'error (or err json-null))))))

(defun bench-scan-limitations (dir)
  (let ((text (mapconcat
               (lambda (file)
                 (condition-case nil
                     (with-temp-buffer
                       (insert-file-contents file)
                       (buffer-substring-no-properties (point-min) (point-max)))
                   (error "")))
               (bench-source-files dir) "\n"))
        (tools nil) (gui nil) (caps nil))
    (let ((pos 0)
          (re "executable-find[ \t\n]+\"\\([^\"\n]+\\)\""))
      (while (string-match re text pos)
        (push (match-string 1 text) tools)
        (setq pos (match-end 0))))
    (dolist (sym '("display-graphic-p" "gui-get-selection" "x-create-frame"
                   "window-system" "tool-bar-mode" "menu-bar-mode"
                   "image-type-available-p" "xwidget" "child-frame"))
      (when (string-match-p (regexp-quote sym) text)
        (push sym gui)))
    (dolist (pair '(("sqlite" . "sqlite-\\(?:available-p\\|open\\|execute\\|close\\)\\|emacsql-sqlite\\|require 'sqlite")
                    ("libxml" . "libxml-parse\\|require 'libxml")
                    ("gnutls" . "gnutls-\\(?:available-p\\|negotiate\\|trustfiles\\)")
                    ("json-parse" . "json-parse-")
                    ("native-compile" . "native-comp-\\(?:available-p\\|compile\\)")))
      (when (string-match-p (cdr pair) text)
        (push (car pair) caps)))
    (list (cons 'external_tools (vconcat (sort (delete-dups tools) #'string<)))
          (cons 'gui_features (vconcat (sort (delete-dups gui) #'string<)))
          (cons 'capability_hints (vconcat (sort (delete-dups caps) #'string<))))))

(defun bench-environment ()
  (list (cons 'emacs_version emacs-version)
        (cons 'system system-configuration)
        (cons 'window_system (format "%s" window-system))
        (cons 'graphic (if (display-graphic-p) t :json-false))
        (cons 'sqlite (if (and (fboundp 'sqlite-available-p)
                               (sqlite-available-p))
                          t :json-false))
        (cons 'gnutls (if (and (fboundp 'gnutls-available-p)
                               (gnutls-available-p))
                          t :json-false))
        (cons 'json (if (fboundp 'json-available-p)
                        (if (json-available-p) t :json-false)
                      t))
        (cons 'native_comp (if (fboundp 'native-comp-available-p)
                               (if (native-comp-available-p) t :json-false)
                             :json-false))
        (cons 'threads (if (fboundp 'make-thread) t :json-false))
        (cons 'modules (if (fboundp 'module-load) t :json-false))
        (cons 'executables
              (mapcar (lambda (tool)
                        (cons (intern tool)
                              (if (executable-find tool) t :json-false)))
                      '("git" "rg" "python3" "node" "sqlite3" "pdflatex"
                        "R" "java" "clang" "cmake" "make" "gcc" "lua"
                        "go" "cargo" "php" "tsc")))))

(defun bench-run ()
  (let (install compile load desc dir fatal)
    (bench-archive-setup)
    (setq install (bench-install))
    (condition-case e
        (package-activate-all)
      (error (bench-note "package-activate-all: %s" (error-message-string e))))
    (setq desc (bench-package-desc))
    (setq dir (and desc (ignore-errors (package-desc-dir desc))))
    (if (or (and dir (file-directory-p dir))
            (locate-library (symbol-name bench-pkg)))
        (progn
          (bench-note "package dir: %s" (or dir "built-in"))
          (setq compile (bench-compile (and dir (file-directory-p dir) dir)))
          (setq load (bench-load (and dir (file-directory-p dir) dir))))
      (setq compile (list (cons 'status "no-package-dir")
                          (cons 'files 0) (cons 'compiled 0)
                          (cons 'warnings 0) (cons 'warning_samples nil)
                          (cons 'errors nil) (cons 'error_samples nil)
                          (cons 'seconds 0)))
      (setq load (list (cons 'status "no-package-dir")
                       (cons 'file json-null) (cons 'feature :json-false)
                       (cons 'seconds 0)
                       (cons 'error "package directory not found"))))
    (list (cons 'package (symbol-name bench-pkg))
          (cons 'source
            (let* ((entry (assq bench-pkg package-archive-contents))
                   (adesc (and entry (car (cdr entry))))
                   (a (or (and desc (package-desc-archive desc))
                          (and adesc (package-desc-archive adesc)))))
              (cond ((bench-local-tar) "local")
                    (desc (if a (format "%s" a) "unknown"))
                    ((locate-library (symbol-name bench-pkg)) "builtin")
                    (t "unknown"))))
          (cons 'version (if desc (package-version-join (package-desc-version desc)) "builtin"))
          (cons 'summary (if desc (package-desc-summary desc) "Built-in package"))
          (cons 'install install)
          (cons 'byte_compile compile)
          (cons 'load load)
          (cons 'limitations (if (and dir (file-directory-p dir))
                                 (bench-scan-limitations dir)
                               (list (cons 'external_tools [])
                                     (cons 'gui_features [])
                                     (cons 'capability_hints []))))
          (cons 'environment (bench-environment))
          (cons 'tested_at (format-time-string "%Y-%m-%dT%H:%M:%S%z"))
          (cons 'duration_seconds (round (- (float-time) bench-start)))
          (cons 'notes (nreverse bench-notes)))))

(condition-case fatal
    (let ((data (bench-run)))
      (bench-write bench-result (bench-json data))
      (bench-write (concat (file-name-sans-extension bench-result) ".log")
                   (format "%S\n" data)))
  (error
   (let ((msg (error-message-string fatal)))
     (bench-write bench-result
                  (bench-json (list (cons 'package (symbol-name bench-pkg))
                                    (cons 'fatal_error msg)
                                    (cons 'tested_at (format-time-string "%Y-%m-%dT%H:%M:%S%z")))))
     (bench-write (concat (file-name-sans-extension bench-result) ".log")
                  (format "FATAL: %s\n" msg)))))

(kill-emacs 0)
;;; runner.el ends here
