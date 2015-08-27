/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */
package com.pivotshare.hls.loader {

    import flash.display.DisplayObject;
    import flash.events.*;
    import flash.net.*;
    import flash.utils.ByteArray;
    import flash.utils.getTimer;
    import flash.utils.Timer;
    import org.mangui.hls.constant.HLSLoaderTypes;
    import org.mangui.hls.event.HLSError;
    import org.mangui.hls.event.HLSEvent;
    import org.mangui.hls.event.HLSLoadMetrics;
    import org.mangui.hls.HLS;
    import org.mangui.hls.model.Fragment;
    import org.mangui.hls.model.FragmentData;
    import org.mangui.hls.utils.AES;

    CONFIG::LOGGING {
        import org.mangui.hls.utils.Log;
        import org.mangui.hls.utils.Hex;
    }

    /**
     * HLS Fragment Streamer, which also handles decryption.
     * Tries to parallel URLStream design pattern, but is incomplete.
     *
     * See [Reading and writing a ByteArray](http://help.adobe.com/en_US/as3/dev/WS5b3ccc516d4fbf351e63e3d118666ade46-7d54.html)
     *
     * @class    FragmentStream
     * @extends  EventDispatcher
     * @author   HGPA
     */
    public class FragmentStream extends EventDispatcher {

        /*
         * DisplayObject needed by AES decrypter.
         */
        private var _displayObject : DisplayObject;

        /*
         * Fragment being loaded.
         */
        private var _fragment : Fragment;

        /*
         * URLStream used to download current Fragment.
         */
        private var _fragmentURLStream : URLStream;

        /**
         * Create a FragmentStream.
         *
         * This constructor takes a reference to main DisplayObject, e.g. stage,
         * necessary for AES decryption control.
         *
         * TODO: It would be more appropriate to create a factory that itself
         * takes the DisplayObject (or a more flexible version of AES).
         *
         * @constructor
         * @param  {DisplayObject}  displayObject
         */
        public function FragmentStream(displayObject : DisplayObject) : void {
            _displayObject = displayObject;
        };

        /*
         * Return FragmentData of Fragment currently being downloaded.
         * Of immediate interest is the `bytes` field.
         *
         * @method getFragment
         * @return  {Fragment}
         */
        public function getFragment() : Fragment {
            return _fragment;
        }

        /*
         * Close the stream.
         *
         * @method  close
         */
        public function close() : void {
            if (_fragmentURLStream && _fragmentURLStream.connected) {
                _fragmentURLStream.close();
            }

            if (_fragment) {

                if (_fragment.data.decryptAES) {
                    _fragment.data.decryptAES.cancel();
                    _fragment.data.decryptAES = null;
                }

                // Explicitly release memory
                // http://help.adobe.com/en_US/FlashPlatform/reference/actionscript/3/flash/utils/ByteArray.html#clear()
                _fragment.data.bytes.clear();
                _fragment.data.bytes = null;
            }
        }

        /**
         * Load a Fragment.
         *
         * This class/methods DOES NOT user reference of parameter. Instead it
         * clones the Fragment and manipulates this internally.
         *
         * @method  load
         * @param   {Fragment}   fragment  -  Fragment with details (cloned)
         * @param   {ByteArray}  key       -  Encryption Key
         * @return  {HLSLoadMetrics}
         */
        public function load(fragment : Fragment, key : ByteArray) : HLSLoadMetrics {

            // Clone Fragment, with new initilizations of deep fields
            // Passing around references is what is causing problems.
            // FragmentData is initialized as part of construction
            _fragment = new Fragment(
                fragment.url,
                fragment.duration,
                fragment.level,
                fragment.seqnum,
                fragment.start_time,
                fragment.continuity,
                fragment.program_date,
                fragment.decrypt_url,
                fragment.decrypt_iv, // We need this reference
                fragment.byterange_start_offset,
                fragment.byterange_end_offset,
                new Vector.<String>()
            )

            _fragmentURLStream = new URLStream();

            // START (LOADING) METRICS
            // Event listener callbacks enclose _metrics
            var _metrics : HLSLoadMetrics = new HLSLoadMetrics(HLSLoaderTypes.FRAGMENT_MAIN);
            _metrics.level = _fragment.level;
            _metrics.id    = _fragment.seqnum;
            _metrics.loading_request_time = getTimer();

            // String used to identify fragment in debug messages
            CONFIG::LOGGING {
                var fragmentString : String = "Fragment[" + _fragment.level + "][" + _fragment.seqnum + "]";
            }

            //
            // See `onLoadProgress` first.
            //

            /*
             * Called when Fragment is processing which may inclue decryption.
             *
             * To access data, call `Fragment.getFragment`, which will include
             * all bytes loaded to this point, with FragmentData's ByteArray
             * having the expected position
             *
             * NOTE: This was `FragmentLoader._fragDecryptProgressHandler` before refactor.
             *
             * @method  onProcess
             * @param   {ByteArray}  data  -  *Portion* of data that finished processing
             */
            var onProcess : Function = function onProcess(data : ByteArray) : void {

                // Ensure byte array pointer starts at beginning
                data.position = 0;

                var bytes : ByteArray = _fragment.data.bytes;

                // Byte Range Business
                // TODO: Confirm this is still working
                if (_fragment.byterange_start_offset != -1) {

                    _fragment.data.bytes.position = _fragment.data.bytes.length;
                    _fragment.data.bytes.writeBytes(data);

                    // if we have retrieved all the data, disconnect loader and notify fragment complete
                    if (_fragment.data.bytes.length >= _fragment.byterange_end_offset) {
                        if (_fragmentURLStream.connected) {
                            _fragmentURLStream.close();
                            onProcessComplete(null);
                        }
                    }
                } else {
                    // Append data to Fragment, but then reset position to mimic
                    // expected pattern of URLStream
                    var fragmentPosition : int = _fragment.data.bytes.position;
                    _fragment.data.bytes.position = _fragment.data.bytes.length;
                    _fragment.data.bytes.writeBytes(data);
                    _fragment.data.bytes.position = fragmentPosition;
                }

                var progressEvent : ProgressEvent = new ProgressEvent(
                    ProgressEvent.PROGRESS,
                    false,
                    false,
                    _fragment.data.bytes.length, // bytesLoaded
                    _fragment.data.bytesTotal    // bytesTotal
                    );

                dispatchEvent(progressEvent);
            }

            /*
             * Called when Fragment has completed processing.
             * May or may not include decryption.
             *
             * NOTE: This was `FragmentLoader._fragDecryptCompleteHandler`
             * before refactor.
             *
             * @method  onProcessComplete
             * @param   {ByteArray}  data  -  Portion of data finished processing
             */
            var onProcessComplete : Function = function onProcessComplete() : void {

                // END DECRYPTION METRICS
                // garbage collect AES decrypter
                if (_fragment.data.decryptAES) {
                    _metrics.decryption_end_time = getTimer();
                    var decrypt_duration : Number = _metrics.decryption_end_time - _metrics.decryption_begin_time;
                    CONFIG::LOGGING {
                        Log.debug("FragmentStream#onProcessComplete: Decrypted duration/length/speed:" +
                            decrypt_duration + "/" + _fragment.data.bytesLoaded + "/" +
                            Math.round((8000 * _fragment.data.bytesLoaded / decrypt_duration) / 1024) + " kb/s");
                    }

                    _fragment.data.decryptAES = null;
                }

                var completeEvent : Event = new ProgressEvent(Event.COMPLETE);
                dispatchEvent(completeEvent);
            }

            /*
             * Called when URLStream has download a portion of the file fragment.
             * This event callback delegates to decrypter if necessary.
             * Eventually onProcess is called when the downloaded portion has
             * finished processing.
             *
             * NOTE: Was `_fragLoadCompleteHandler` before refactor
             *
             * @param  {ProgressEvent}  evt  -  Portion of data finished processing
             */
            var onLoadProgress : Function = function onProgress(evt : ProgressEvent) : void {

                // First call of onProgress for this Fragment
                // Initilize fields in Fragment and FragmentData
                if (_fragment.data.bytes == null) {

                    _fragment.data.bytes = new ByteArray();
                    _fragment.data.bytesLoaded = 0;
                    _fragment.data.bytesTotal = evt.bytesTotal;
                    _fragment.data.flushTags();

                    // NOTE: This may be wrong, as it is only called after data
                    // has been loaded.
                    _metrics.loading_begin_time = getTimer();

                    CONFIG::LOGGING {
                        Log.debug("FragmentStream#onLoadProgress: Downloaded " +
                            fragmentString + "'s first " + evt.bytesLoaded +
                            " bytes of " + evt.bytesTotal + " Total");
                    }

                    // decrypt data if needed
                    if (_fragment.decrypt_url != null) {
                        // START DECRYPTION METRICS
                        _metrics.decryption_begin_time = getTimer();
                        CONFIG::LOGGING {
                            Log.debug("FragmentStream#onLoadProgress: " + fragmentString + " needs to be decrypted");
                        }

                        _fragment.data.decryptAES = new AES(
                            _displayObject,
                            key,
                            _fragment.decrypt_iv,
                            onProcess,
                            onProcessComplete
                            );
                    } else {
                        _fragment.data.decryptAES = null;
                    }
                }

                if (evt.bytesLoaded > _fragment.data.bytesLoaded && _fragmentURLStream.bytesAvailable > 0) {  // prevent EOF error race condition

                    // bytes from URLStream
                    var data : ByteArray = new ByteArray();
                    _fragmentURLStream.readBytes(data);

                    // Mark that bytes have been loaded, but do not store these
                    // bytes yet
                    _fragment.data.bytesLoaded += data.length;

                    if (_fragment.data.decryptAES != null) {
                        _fragment.data.decryptAES.append(data);
                    } else {
                        onProcess(data);
                    }
                }
            }

            /*
             * Called when URLStream had completed downloading.
             *
             * @param  {Event}  evt  -  Portion of data finished processing
             */
            var onLoadComplete : Function = function onLoadComplete(evt : Event) : void {
                // load complete, reset retry counter
                //_fragRetryCount = 0;
                //_fragRetryTimeout = 1000;

                if (_fragment.data.bytes == null) {
                    CONFIG::LOGGING {
                        Log.warn("FragmentStream#onLoadComplete: " + fragmentString +
                            " size is null, invalidate it and load next one");
                    }
                    //_levels[_hls.loadLevel].updateFragment(_fragCurrent.seqnum, false);
                    //_loadingState = LOADING_IDLE;

                    // TODO: Dispatch an error

                    return;
                }

                CONFIG::LOGGING {
                    Log.debug("FragmentStream#onLoadComplete: " + fragmentString +
                        " has finished downloading, but may still be decrypting");
                }

                // TODO: ???
                //_fragSkipping = false;

                // END LOADING METRICS
                _metrics.loading_end_time = getTimer();
                _metrics.size = _fragment.data.bytesLoaded;
                var _loading_duration : uint = _metrics.loading_end_time - _metrics.loading_request_time;
                CONFIG::LOGGING {
                    Log.debug("FragmentStream#onLoadComplete: Loading duration/RTT/length/speed:" +
                        _loading_duration + "/" +
                        (_metrics.loading_begin_time - _metrics.loading_request_time) + "/" +
                        _metrics.size + "/" +
                        Math.round((8000 * _metrics.size / _loading_duration) / 1024) + " kb/s");
                }

                if (_fragment.data.decryptAES) {
                    _fragment.data.decryptAES.notifycomplete(); // Calls onProcessComplete by proxy
                } else {
                    onProcessComplete();
                }
            }

            /*
             * Called when URLStream has Errored.
             * @param  {ErrorEvent}  evt  -  Portion of data finished processing
             */
            var onLoadError : Function = function onLoadError(evt : ErrorEvent) : void {

                CONFIG::LOGGING {
                    Log.error("FragmentStream#onLoadError: " + evt.text);
                }

                // Forward error
                dispatchEvent(evt);
            }

            _fragmentURLStream.addEventListener(IOErrorEvent.IO_ERROR, onLoadError);
            _fragmentURLStream.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onLoadError);
            _fragmentURLStream.addEventListener(ProgressEvent.PROGRESS, onLoadProgress);
            _fragmentURLStream.addEventListener(Event.COMPLETE, onLoadComplete);

            _fragmentURLStream.load(new URLRequest(fragment.url));

            return _metrics;
        }

    }
}
