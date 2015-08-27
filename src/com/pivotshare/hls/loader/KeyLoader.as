/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */
package com.pivotshare.hls.loader {

    import flash.events.*;
    import flash.net.*;
    import flash.utils.ByteArray;
    import flash.utils.getTimer;
    import flash.utils.Timer;

    import org.mangui.hls.event.HLSError;

    CONFIG::LOGGING {
        import org.mangui.hls.utils.Log;
        import org.mangui.hls.utils.Hex;
    }

    /**
     * Encryption Key loader.
     *
     * - Instantiations cache loaded keys
     * - Uses Javascript-style callback functions
     *
     * @class   KeyLoader
     * @author  HGPA
     */
    public class KeyLoader {

        /*
         * Cache Object of Keys, where URL is the Object key and the Encryption
         * Key is the value.
         */
        private var _keymap : Object;

        /*
         * Map of currently active keyloaders.
         */
        private var _keyURLStreams : Object;

        /**
         * Create the Encryption Key Loader.
         *
         * @constructor
         */
        public function KeyLoader() : void {
            _keymap = new Object();
            _keyURLStreams = new Object();
        };

        /**
         * Load key from URL, if necessary.
         *
         * `callback` is a JavaScript-callback that in the form of
         *
         *     function (err : Error, key : ByteArray) {}
         *
         * @method  load
         * @param   {String}    url       -  URL of Key
         * @param   {Function}  callback  -  JavaScript-style callback
         */
        public function load(url : String, callback : Function) : void {

            // There is no key to load
            if (!url) {
                callback(null, null);
                return;
            }

            // We've already loaded this key
            if (_keymap[url] != undefined) {
                callback(null, _keymap[url]);
                return;
            }

            //
            // We need to load this key
            //

            _keyURLStreams[url] = new URLStream();

            /*
             * When URLStream is complete
             *
             * @param  {Event}  evt
             */
            var onComplete : Function = function onComplete(evt : Event) : void {

                // Keys MUST be exactly 16 bytes long
                if (!_keyURLStreams[url].bytesAvailable == 16) {
                    var err : HLSError = new HLSError(HLSError.KEY_PARSING_ERROR, url, "invalid key size: received " + _keyURLStreams[url].bytesAvailable + " / expected 16 bytes");
                    callback(err, null)
                    return;
                }

                var keyData : ByteArray = new ByteArray();
                _keyURLStreams[url].readBytes(keyData, 0, 0);
                _keymap[url] = keyData;

                CONFIG::LOGGING {
                    Log.debug("KeyLoader#onComplete: Loaded key " + Hex.fromArray(keyData) + " from " + url);
                }

                // Cleanup
                _keyURLStreams[url].removeEventListener(IOErrorEvent.IO_ERROR, onError);
                _keyURLStreams[url].removeEventListener(SecurityErrorEvent.SECURITY_ERROR, onError);
                _keyURLStreams[url].removeEventListener(Event.COMPLETE, onComplete);
                delete _keyURLStreams[url];

                callback(null, keyData);
                return;
            };

            /*
             * When URLStream is *Error
             *
             * - IOErrorEvent
             * - SecurityErrorEvent
             *
             * @param  {Event}  evt
             */
            var onError : Function = function onError(evt : Event) : void {

                var err : HLSError;

                if (evt is IOErrorEvent) {
                    err = new HLSError(HLSError.KEY_LOADING_ERROR, url, "I/O Error");
                }
                else if (evt is SecurityErrorEvent) {
                    err = new HLSError(HLSError.KEY_LOADING_CROSSDOMAIN_ERROR, url, "Cannot load key: crossdomain access denied");
                }
                else {
                    err = new HLSError(HLSError.OTHER_ERROR, url, "Unknown Error");
                }

                // Cleanup
                _keyURLStreams[url].removeEventListener(IOErrorEvent.IO_ERROR, onError);
                _keyURLStreams[url].removeEventListener(SecurityErrorEvent.SECURITY_ERROR, onError);
                _keyURLStreams[url].removeEventListener(Event.COMPLETE, onComplete);
                delete _keyURLStreams[url];

                callback(err, null);
                return;
            };

            //
            // We do not register a HTTPStatusEvent.HTTP_STATUS listener, as doing
            // so suppresses IO_ERROR. See [flash.net.URLStream](http://help.adobe.com/en_US/FlashPlatform/reference/actionscript/3/flash/net/URLStream.html#event:httpResponseStatus)
            //

            _keyURLStreams[url].addEventListener(IOErrorEvent.IO_ERROR, onError);
            _keyURLStreams[url].addEventListener(SecurityErrorEvent.SECURITY_ERROR, onError);
            _keyURLStreams[url].addEventListener(Event.COMPLETE, onComplete);

            _keyURLStreams[url].load(new URLRequest(url));

            CONFIG::LOGGING {
                Log.debug("KeyLoader#load: Started loading of key at " + url);
            }
        }

        /**
         * Get key, if available.
         *
         * @method  getKey
         * @param   {String}     url  -  URL of Key
         * @return  {ByteArray}  Key
         */
        public function getKey(url : String) : ByteArray {
            return _keymap[url];
        }
    }
}
