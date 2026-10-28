;;; .emacs --- HarmonyOS terminal integration  -*- lexical-binding: t; -*-
;; Clipboard integration for the HarmonyOS terminal (installed by the HAP).
(setq tty-select-active-regions t)
;; Use the CA bundle shipped with the HAP (the sandbox has no system store).
(setq gnutls-trustfiles
      (list (expand-file-name "../etc/ssl/ca-bundle.crt" (getenv "HOME"))))
(setq select-enable-clipboard t)
(when (fboundp 'set-terminal-parameter)
  (ignore-errors
    (set-terminal-parameter nil 'xterm--get-selection t)
    (set-terminal-parameter nil 'xterm--set-selection t)))
(defun ohos-clipboard-text ()
  "Return the system clipboard text, or nil."
  (ignore-errors (gui-get-selection 'CLIPBOARD)))
(defvar ohos-last-clipboard ""
  "Last clipboard text inserted by `ohos-yank'.")

(defun ohos-yank ()
  "Yank fresh system clipboard text, otherwise the kill ring."
  (interactive)
  (let ((text (ohos-clipboard-text)))
    (cond
     ((and text (> (length text) 0)
           (not (equal text ohos-last-clipboard)))
      (setq ohos-last-clipboard text)
      (insert-for-yank text))
     (kill-ring
      (yank))
     (t
      (message "剪贴板不可用：请先点击底部「粘贴」按钮授权读取")))))
(global-set-key (kbd "C-y") #'ohos-yank)
(provide 'ohos-clipboard)
;;; .emacs ends here
