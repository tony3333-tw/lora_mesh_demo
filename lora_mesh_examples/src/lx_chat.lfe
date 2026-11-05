;;;
;;; Chat from the terminal, like serial_chat.py and tcp_chat.py.
;;; The LFE twin of ex_chat.erl.
;;;
;;;   lme chat --lfe -d Alice
;;;
;;; Commands: TEXT or send TEXT, to NAME, to #N, contacts, q / quit
;;;

(defmodule lx_chat
  (export (run 1)))

;; dest: (tuple 'node id name) | (tuple 'channel n)
(defrecord chat
  client
  names
  nodes
  dest
  protocol)

(defun run (opts)
  (let* ((client (lmc:connect opts))
         (nodes (lmc:nodes client 1000))
         (who (maps:get 'dest opts "Alice"))
         (chat (make-chat client client
                          names (lmc:names nodes)
                          nodes nodes
                          protocol (maps:get 'protocol opts 'meshcore))))
    (lmc:subscribe client 'rx)
    (case (destination who chat)
      ((tuple 'ok dest)
       (let ((self (self)))
         (spawn_link (lambda () (read-lines self))))
       (io:format "Talking to ~ts. Commands: to NAME, to #N, contacts, quit~n"
                  (list (dest-name dest)))
       (loop (set-chat-dest chat dest)))
      ('error
       (io:format "Contact '~ts' not found in contacts.~n" (list who))))
    (lmc:disconnect client)))

;; stdin is read by its own process, so messages print while we wait
(defun read-lines (parent)
  (case (io:get_line "")
    ('eof
     (! parent (tuple 'line 'eof)))
    ((tuple 'error _)
     (! parent (tuple 'line 'eof)))
    (line
     (! parent (tuple 'line (string:trim line 'trailing "\r\n")))
     (read-lines parent))))

(defun loop (chat)
  (receive
    ((tuple 'line 'eof)
     'ok)
    ((tuple 'line line)
     (case (command line chat)
       ('quit 'ok)
       (chat2 (loop chat2))))
    ((tuple 'publish msg)
     (case (lmc:decode (chat-client chat) msg)
       ((tuple 'rx rx)
        (io:format "~ts: ~ts~n"
                   (list (lmc:sender rx (chat-names chat))
                         (maps:get #"text" rx)))
        (loop chat))
       ((tuple 'node node)
        (loop (set-chat-names chat (lmc:add_name (chat-names chat) node))))
       ('ignore
        (loop chat))))))

(defun command
  (("q" _chat)
   'quit)
  (("quit" _chat)
   'quit)
  (("" chat)
   chat)
  (("contacts" chat)
   (lists:foreach
    (lambda (node)
      (case (maps:get #"long_name" node)
        ('null 'ok)
        (name (io:format "  ~-15ts ~ts~n" (list (maps:get #"id" node) name)))))
    (chat-nodes chat))
   chat)
  (((++ "to " who) chat)
   (case (destination who chat)
     ((tuple 'ok dest)
      (io:format "now talking to ~ts~n" (list (dest-name dest)))
      (set-chat-dest chat dest))
     ('error
      (io:format "Contact '~ts' not found in contacts.~n" (list who))
      chat)))
  (((++ "send " text) chat)
   (say text chat))
  ((text chat)
   (say text chat)))

(defun say (text chat)
  (let ((tx (case (chat-dest chat)
              ((tuple 'node id _name)
               (map 'to id 'text text))
              ((tuple 'channel n)
               (map 'channel n 'protocol (chat-protocol chat) 'text text)))))
    (lmc:send (chat-client chat) tx)
    (io:format " Sent~n")
    chat))

(defun destination
  (((cons #\# n) _chat)
   (try
     (tuple 'ok (tuple 'channel (list_to_integer n)))
     (catch
       ((tuple 'error 'badarg _) 'error))))
  ((who chat)
   (case (lmc:find (chat-nodes chat) who)
     ((tuple 'ok node)
      (tuple 'ok (tuple 'node
                        (maps:get #"id" node)
                        (maps:get #"long_name" node))))
     ('error
      'error))))

(defun dest-name
  (((tuple 'node _id name))
   name)
  (((tuple 'channel n))
   (io_lib:format "channel ~p" (list n))))
