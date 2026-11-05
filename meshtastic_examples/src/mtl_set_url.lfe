;;;
;;; Show the radio's channel URL, or set its channels from one, like
;;; set-URL.py. The LFE twin of mte_set_url.erl.
;;;
;;;   mte set-url --lfe                 print the current URL
;;;   mte set-url --lfe --url 'https://meshtastic.org/e/#CgcSAQE6AggNEgwIATgBQANIAVAeaAE'
;;;

(defmodule mtl_set_url
  (export (run 1)))

(defun run (opts)
  (let ((c (mtc:connect opts)))
    (io:format "~s~n" (list (url c)))
    (case (maps:find 'url opts)
      ((tuple 'ok url)
       (let ((result (set-url c url)))
         (mtc:close c)
         (case result
           ('ok
            (timer:sleep 4000)
            (let ((c2 (reconnect opts 5)))
              (io:format "~s~n" (list (url c2)))
              (mtc:close c2)))
           ('error
            'ok))))
      ('error
       (mtc:close c)))))

;; node.getURL(): primary and secondary channels' settings and the LoRa
;; config, as a ChannelSet in URL-safe base64 without padding
(defun url (c)
  (let* ((settings (lists:filtermap
                    (lambda (ch)
                      (case (maps:get 'role ch)
                        ('DISABLED 'false)
                        (_ (tuple 'true (maps:get 'settings ch)))))
                    (mtc:channels c)))
         (set (map 'settings settings 'lora_config (mtc:config c 'lora)))
         (b64 (base64:encode (mtc:encode set 'channel_set)
                             (map 'mode 'urlsafe 'padding 'false))))
    (list "https://meshtastic.org/e/#" b64)))

;; node.setURL(url): channel 0 primary, the others secondary, then the
;; LoRa config. -> 'ok | 'error
(defun set-url (c url)
  (case (string:split url "/#")
    ((list _ b64)
     (let* ((set (mtc:decode (base64:decode b64 (map 'mode 'urlsafe 'padding 'false))
                             'channel_set))
            (settings (maps:get 'settings set '())))
       (case settings
         ('()
          (io:format "Warning: There were no settings.~n")
          'error)
         (_
          (lists:foreach
           (lambda (i-s)
             (let ((index (- (element 1 i-s) 1)))
               (admin-ok c (map 'set_channel (map 'index index
                                                  'role (role index)
                                                  'settings (element 2 i-s))))))
           (lists:enumerate settings))
          (admin-ok c (map 'set_config (map 'lora (maps:get 'lora_config set (map)))))
          (io:format "Set ~p channel(s) and the LoRa config~n" (list (length settings)))
          'ok))))
    (_
     (io:format "Warning: Invalid URL '~ts'~n" (list url))
     'error)))

(defun role
  ((0) 'PRIMARY)
  ((_) 'SECONDARY))

(defun admin-ok (c admin)
  (let ((id (mtc:admin c admin)))
    (case (mtc:ack c id 10000)
      ('ok 'ok))))

;; the radio may be restarting
(defun reconnect (opts tries)
  (try
    (mtc:connect opts)
    (catch
      ((tuple 'error (tuple 'radio_connect reason) stack)
       (if (> tries 1)
         (progn
           (timer:sleep 3000)
           (reconnect opts (- tries 1)))
         (erlang:raise 'error (tuple 'radio_connect reason) stack))))))
