;;;
;;; Send what is typed, print what is received, like send-and-receive.py.
;;; The LFE twin of mte_chat.erl.
;;;
;;;   mte chat --lfe                  to everyone on channel 0
;;;   mte chat --lfe -c 1             to everyone on channel 1
;;;   mte chat --lfe -d "Hill top"    direct messages to one node
;;;
;;; "quit" (or Ctrl-D) ends.
;;;

(defmodule mtl_chat
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (names (mtc:names (mtc:nodes c opts)))
         (send (if (maps:is_key 'dest opts)
                 (map 'to (mtc:dest c opts))
                 (map 'channel (maps:get 'channel opts 0))))
         (self (self)))
    (mtc:subscribe c 'rx)
    (spawn_link (lambda () (read-lines self)))
    (loop c names send)
    (mtc:disconnect c)))

;; stdin is read by its own process, so messages print while we wait
(defun read-lines (parent)
  (case (io:get_line "> ")
    ('eof
     (! parent (tuple 'line 'eof)))
    ((tuple 'error _)
     (! parent (tuple 'line 'eof)))
    (line
     (! parent (tuple 'line (string:trim line 'trailing "\r\n")))
     (read-lines parent))))

(defun loop (c names send)
  (receive
    ((tuple 'line 'eof)
     'ok)
    ((tuple 'line "quit")
     'ok)
    ((tuple 'line "")
     (loop c names send))
    ((tuple 'line text)
     (mtc:send_text c text send)
     (loop c names send))
    ((tuple 'publish msg)
     (case (mtc:decode c msg)
       ((tuple 'rx rx)
        (io:format "~ts: ~ts~n> "
                   (list (mtc:sender rx names)
                         (maps:get #"text" rx))))
       (_other
        'ok))
     (loop c names send))))
