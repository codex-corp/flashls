/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */
package com.pivotshare.hls.loader {

    import flash.events.*;
    import flash.net.*;
    import flash.utils.ByteArray;
    import flash.utils.getTimer;
    import flash.utils.Timer;

    import com.pivotshare.hls.loader.FragmentStream;
    import com.pivotshare.hls.loader.KeyLoader;

    import org.mangui.hls.constant.HLSLoaderTypes;
    import org.mangui.hls.constant.HLSTypes;
    import org.mangui.hls.controller.AudioTrackController;
    import org.mangui.hls.controller.LevelController;
    import org.mangui.hls.demux.Demuxer;
    import org.mangui.hls.demux.DemuxHelper;
    import org.mangui.hls.demux.ID3Tag;
    import org.mangui.hls.event.HLSError;
    import org.mangui.hls.event.HLSEvent;
    import org.mangui.hls.event.HLSLoadMetrics;
    import org.mangui.hls.flv.FLVTag;
    import org.mangui.hls.HLS;
    import org.mangui.hls.HLSSettings;
    import org.mangui.hls.model.AudioTrack;
    import org.mangui.hls.model.Fragment;
    import org.mangui.hls.model.FragmentData;
    import org.mangui.hls.model.Level;
    import org.mangui.hls.stream.StreamBuffer;

    CONFIG::LOGGING {
        import org.mangui.hls.utils.Log;
        import org.mangui.hls.utils.Hex;
    }

    /**
     * FlasHLS-compatible Fragment loader.
     *
     * Utilizes FragmentStream and KeyLoader from com.pivotshare.hls.
     *
     * @class   FragmentLoader
     * @author  HGPA
     */
    public class FragmentLoader {

        //
        //
        // FragmentLoader loop states
        // See _checkBuffer method
        //
        //

        public static const LOADING_STOPPED              : int = -1;
        public static const LOADING_IDLE                 : int = 0;
        public static const LOADING_IN_PROGRESS          : int = 1;
        public static const LOADING_WAITING_LEVEL_UPDATE : int = 2;
        public static const LOADING_STALLED              : int = 3;
        public static const LOADING_FRAGMENT_IO_ERROR    : int = 4;
        public static const LOADING_KEY_IO_ERROR         : int = 5;
        public static const LOADING_COMPLETED            : int = 6;

        //
        //
        // References to external instantiations
        //
        //

        private var _hls : HLS;
        private var _levelController : LevelController;
        private var _audioTrackController : AudioTrackController;

        /** Timer used control FragmentLoader event loop. */
        private var _timer : Timer;

        /** Encryption Key Loader */
        private var _keyLoader : KeyLoader;

        /**
         * Reference to the manifest levels.
         * This is set via _manifestLoadedHandler.
         */
        private var _levels : Vector.<Level>;

        /* demux instance */
        private var _demux : Demuxer;

        /** stream buffer instance */
        private var _streamBuffer : StreamBuffer;

        /** Util for loading the fragment. */
        private var _fragstreamloader : URLStream;

        private var _fragmentStream : FragmentStream;

        /** reference to previous/current fragment */
        private var _fragPrevious : Fragment;
        private var _fragCurrent : Fragment;

        /** loading metrics */
        private var _metrics : HLSLoadMetrics;

        //
        //
        // Secondary state variables
        //
        //

        /* loading state variable */
        private var _loadingState : int;

        /** has manifest just being reloaded **/
        private var _manifestJustLoaded : Boolean;

        /** last loaded level. **/
        private var _levelLastLoaded : int;

        /** next level (-1 if not defined yet) **/
        private var _levelNext : int = -1;

        /** Did the stream switch quality levels. **/
        private var _switchLevel : Boolean;

        /** Did a discontinuity occurs in the stream **/
        private var _hasDiscontinuity : Boolean;

        /** boolean to track whether PTS analysis is ongoing or not */
        private var _ptsAnalyzing : Boolean = false;

        /** requested seek position **/
        private var _seekPosition : Number;

        /** first fragment loaded ? **/
        private var _fragmentFirstLoaded : Boolean;

        /* key error/reload */
        private var _keyLoadErrorDate : Number;
        private var _keyRetryTimeout : Number;
        private var _keyRetryCount : int;
        private var _keyLoadStatus : int;

        /* fragment error/reload */
        private var _fragLoadErrorDate : Number;
        private var _fragRetryTimeout : Number;
        private var _fragRetryCount : int;
        private var _fragLoadStatus : int;
        private var _fragSkipping : Boolean;

        /*
         * Whether _onDemuxProgress event listener has been called at least once
         * for current Fragment.
         */
        private var _hasDemuxProgressedOnce : Boolean;

        /*
         * Emergency Fragment to be loaded if current Fragment does not start
         * with an IDR.
         */
        private var _emergencyFragment : Fragment;

        /*
         * FragmentDemuxedStream to for emergency Fragment.
         */
        private var _emergencyFragmentDemuxedStream : FragmentDemuxedStream;

        //
        //
        //
        // PUBLIC METHODS
        //
        //
        //

        /**
         * Create the FragmentLoader.
         *
         * @constructor
         * @param  {HLS}                   hls
         * @param  {AudioTrackController}  audioTrackController
         * @param  {LevelController}       levelController
         * @param  {StreamBuffer}          streamBuffer
         */
        public function FragmentLoader(
            hls : HLS,
            audioTrackController : AudioTrackController,
            levelController : LevelController,
            streamBuffer : StreamBuffer) : void {

            _hls = hls;
            _levelController = levelController;
            _audioTrackController = audioTrackController;
            _streamBuffer = streamBuffer;
            _hls.addEventListener(HLSEvent.MANIFEST_LOADED, _manifestLoadedHandler);
            _hls.addEventListener(HLSEvent.LEVEL_LOADED, _levelLoadedHandler);
            _timer = new Timer(20, 0);
            _timer.addEventListener(TimerEvent.TIMER, _checkLoading);
            _loadingState = LOADING_STOPPED;
            _manifestJustLoaded = false;
            _keyLoader = new KeyLoader();

            _hasDemuxProgressedOnce = false;
            _emergencyFragment = null;
            _emergencyFragmentDemuxedStream = null;
        };

        /**
         * Dispose this FragmentLoader.
         *
         * @method  dispose
         */
        public function dispose() : void {
            stop();
            _hls.removeEventListener(HLSEvent.MANIFEST_LOADED, _manifestLoadedHandler);
            _hls.removeEventListener(HLSEvent.LEVEL_LOADED, _levelLoadedHandler);
            _loadingState = LOADING_STOPPED;
            _keyLoader = new KeyLoader();
        }

        /**
         * Load necessary Fragments for requested seeking.
         *
         * @method  seek
         * @param   {Number}  position
         */
        public function seek(position : Number) : void {
            CONFIG::LOGGING {
                Log.debug("FragmentLoader#seek(" + position.toFixed(2) + ")");
            }
            // reset IO Error when seeking
            _fragRetryCount = 0;
            _keyRetryCount = 0;
            _fragRetryTimeout = 1000;
            _keyRetryTimeout = 1000;
            _loadingState = LOADING_IDLE;
            _seekPosition = position;
            _fragmentFirstLoaded = false;
            _fragPrevious = null;
            _fragSkipping = false;
            _timer.start();
        }


        public function seekFromLastFrag(lastFrag : Fragment) : void {
            CONFIG::LOGGING {
                Log.info("FragmentLoader:seekFromLastFrag(level:" + lastFrag.level + ",SN:" + lastFrag.seqnum + ",PTS:" + lastFrag.data.pts_start +")");
            }
            // reset IO Error when seeking
            _fragRetryCount = _keyRetryCount = 0;
            _fragRetryTimeout = _keyRetryTimeout = 1000;
            _loadingState = LOADING_IDLE;
            _fragmentFirstLoaded = true;
            _fragSkipping = false;
            _levelNext = -1;
            _fragPrevious = lastFrag;
            _timer.start();
        }

        /**
         * Stop this FragmentLoader.
         *
         * @method  stop
         */
        public function stop() : void {
            _stop_load();
            _timer.stop();
            _loadingState = LOADING_STOPPED;
        }

        public function get audioExpected() : Boolean {
            if (_demux) {
                return _demux.audioExpected;
            } else {
                // always return true in case demux is not yet initialized
                return true;
            }
        }

        public function get videoExpected() : Boolean {
            if (_demux) {
                return _demux.videoExpected;
            } else {
                // always return true in case demux is not yet initialized
                return true;
            }
        }

        //
        //
        //
        // PRIVATE METHODS
        //
        //
        //

        /**
         * Called when Adaptive Manifest has been loaded.
         *
         * @private
         * @method   _manifestLoadedHandler
         * @param    {HLSEvent}  event  -  HLSEvent.MANIFEST_LOADED
         */
        private function _manifestLoadedHandler(event : HLSEvent) : void {
            _levels = event.levels;
            _manifestJustLoaded = true;
        };

        /**
         * Called when Level Manifest has been loaded.
         *
         * @private
         * @method   _levelLoadedHandler
         * @param    {HLSEvent}  event  -  HLSEvent.LEVEL_LOADED
         */
        private function _levelLoadedHandler(event : HLSEvent) : void {
            _levelLastLoaded = event.loadMetrics.level;
            if (_loadingState == LOADING_WAITING_LEVEL_UPDATE && _levelLastLoaded == _hls.loadLevel) {
                _loadingState = LOADING_IDLE;
            }
            // speed up loading of new fragment
            _timer.start();
        };

        /**
         * Stop the pipeline of the current Fragment.
         *
         * @private
         * @method   _stop_load
         */
        private function _stop_load() : void {

            if (_fragmentStream) {
                _fragmentStream.close();
            }

            // FIXME: Potential bug now that we do not expliclty close key stream load
            // KeyLoader could be changed to allow close of stream, but we'll need some ID/state
            /*
            if (_keystreamloader && _keystreamloader.connected) {
                _keystreamloader.close();
            }
            */

            if (_demux) {
                _demux.cancel();
                _demux = null;
            }
        }

        /**
         * FragmentLoader event loop handler.
         *
         * States:
         *
         * - LOADING_STOPPED
         * - LOADING_WAITING_LEVEL_UPDATE
         * - LOADING_IN_PROGRESS
         * - LOADING_IDLE
         * - LOADING_STALLED
         * - LOADING_KEY_IO_ERROR
         * - LOADING_COMPLETED
         *
         * @private
         * @method   _checkLoading
         * @param    {Event}  e  -  TimerEvent
         */
        private function _checkLoading(e : Event) : void {
            switch(_loadingState) {

                /*
                 * Loading has explicitly been stopped. Stop this loop.
                 */
                case LOADING_STOPPED:
                    stop();
                    break;

                /*
                 * Waiting for Level manifest. Do nothing.
                 */
                case LOADING_WAITING_LEVEL_UPDATE:
                    break;

                /*
                 * Loading already in progress.
                 *
                 * If we are using adaptive bitrate then monitor Fragment
                 * loading to determine if we should stay at current bitrate.
                 */
                case LOADING_IN_PROGRESS:
                     if(_hls.autoLevel && _fragCurrent.level && _fragmentFirstLoaded) {

                        // monitor fragment load progress after half of expected fragment duration,to stabilize bitrate
                        var requestDelay : int = getTimer() - _metrics.loading_request_time;
                        var fragDuration : Number = _fragCurrent.duration;

                        if(requestDelay > 500 * fragDuration) {
                            var loaded : int = _fragCurrent.data.bytesLoaded;
                            var expected : int = fragDuration * _levels[_fragCurrent.level].bitrate / 8;
                            if(expected < loaded) {
                                expected = loaded;
                            }
                            var loadRate : int = loaded*1000/requestDelay; // byte/s
                            var fragLoadedDelay : Number =(expected-loaded)/loadRate;
                            var fragLevel0LoadedDelay : Number = fragDuration*_levels[0].bitrate/(8*loadRate); //bps/Bps
                            var bufferLen : Number = _hls.stream.bufferLength;

                            // CONFIG::LOGGING {
                            //     Log.info("bufferLen/fragDuration/fragLoadedDelay/fragLevel0LoadedDelay:" + bufferLen.toFixed(1) + "/" + fragDuration.toFixed(1) + "/" + fragLoadedDelay.toFixed(1) + "/" + fragLevel0LoadedDelay.toFixed(1));
                            // }
                            /* if we have less than 2 frag duration in buffer and if frag loaded delay is greater than buffer len
                              ... and also bigger than duration needed to load fragment at next level ...*/
                            if(bufferLen < 2*fragDuration && fragLoadedDelay > bufferLen && fragLoadedDelay > fragLevel0LoadedDelay) {
                                // abort fragment loading ...
                                CONFIG::LOGGING {
                                    Log.warn("FragmentLoader#_checkLoading: loading too slow, abort fragment loading");
                                    Log.warn("fragLoadedDelay/bufferLen/fragLevel0LoadedDelay: " + fragLoadedDelay.toFixed(1) + " / " + bufferLen.toFixed(1) + " / " + fragLevel0LoadedDelay.toFixed(1));
                                }
                                //abort fragment loading
                                _stop_load();
                                // fill loadMetrics so please LevelController that will adjust bw for next fragment
                                // fill theoritical value, assuming bw will remain as it is
                                _metrics.size = expected;
                                _metrics.duration = 1000*fragDuration;
                                _metrics.loading_end_time = _metrics.parsing_end_time = _metrics.loading_request_time + 1000*expected/loadRate;
                                _hls.dispatchEvent(new HLSEvent(HLSEvent.FRAGMENT_LOAD_EMERGENCY_ABORTED, _metrics));

                              // switch back to IDLE state to request new fragment at lowest level
                              _loadingState = LOADING_IDLE;
                            }
                        }
                    }
                    break;

                /*
                 * No loading in progress. Start loading.
                 */
                case LOADING_IDLE:
                    var level : int;
                    // check if first fragment after seek has been already loaded
                    if (_fragmentFirstLoaded == false) {

                        CONFIG::LOGGING {
                            Log.debug("FragmentLoader#_checkLoading not _fragmentFirstLoaded");
                        }

                        // select level for first fragment load
                        if(_levelNext != -1) {
                            level = _levelNext;
                        } else if (_hls.autoLevel) {
                            if (_manifestJustLoaded) {
                                level = _hls.startLevel;
                            } else {
                                level = _hls.seekLevel;
                            }
                        } else {
                            level = _hls.manualLevel;
                        }

                        if (level != _hls.loadLevel) {
                            _demux = null;
                            _hls.dispatchEvent(new HLSEvent(HLSEvent.LEVEL_SWITCH, level));
                        }

                        _switchLevel = true;

                        // check if we received playlist for choosen level. if live playlist, ensure that new playlist has been refreshed
                        if ((_levels[level].fragments.length == 0) || (_hls.type == HLSTypes.LIVE && _levelLastLoaded != level)) {
                            // playlist not yet received
                            CONFIG::LOGGING {
                                Log.debug("FragmentLoader#_checkLoading: playlist not received for levels[" + level + "]");
                            }
                            _loadingState = LOADING_WAITING_LEVEL_UPDATE;
                            _levelNext = level;
                        } else {
                            // just after seek, load first fragment
                            CONFIG::LOGGING {
                                Log.debug("FragmentLoader#_checkLoading Will _loadfirstfragment");
                            }
                            _loadingState = _loadfirstfragment(_seekPosition, level);
                        }

                        /* first fragment already loaded
                         * check if we need to load next fragment, do it only if buffer is NOT full
                         */
                    } else if (HLSSettings.maxBufferLength == 0 || _hls.stream.bufferLength < HLSSettings.maxBufferLength) {

                        // select level for next fragment load
                        if(_levelNext != -1) {
                            level = _levelNext;
                        } else if (_hls.autoLevel && _levels.length > 1 ) {
                            // select level from heuristics (current level / last fragment duration / buffer length)
                            level = _levelController.getnextlevel(_hls.loadLevel, _hls.stream.bufferLength);
                        } else if (_hls.autoLevel && _levels.length == 1 ) {
                            level = 0;
                        } else {
                            level = _hls.manualLevel;
                        }

                        // notify in case level switch occurs
                        if (level != _hls.loadLevel) {
                            _switchLevel = true;
                            _demux = null;
                            _hls.dispatchEvent(new HLSEvent(HLSEvent.LEVEL_SWITCH, level));
                        }

                        // check if we received playlist for choosen level. if live playlist, ensure that new playlist has been refreshed
                        if ((_levels[level].fragments.length == 0) || (_hls.type == HLSTypes.LIVE && _levelLastLoaded != level)) {
                            // playlist not yet received
                            CONFIG::LOGGING {
                                Log.debug("FragmentLoader#_checkLoading: playlist not received for levels[" + level + "]");
                            }
                            _loadingState = LOADING_WAITING_LEVEL_UPDATE;
                            _levelNext = level;
                        } else {
                            _loadingState = _loadnextfragment(level, _fragPrevious);
                        }
                    }
                    break;

                /*
                 * Loading has stalled.
                 *
                 * Next consecutive fragment not found, which is possible due
                 * with live playlists:
                 * - if bandwidth available is lower than lowest quality needed bandwidth
                 * - after long pause
                 */
                case LOADING_STALLED:
                    CONFIG::LOGGING {
                        Log.warn("FragmentLoader#_checkLoading: loading stalled so stop fragment loading");
                    }
                    _hls.dispatchEvent(new HLSEvent(HLSEvent.LIVE_LOADING_STALLED));
                    stop();
                    break;

                /*
                 * Encryption key failed to load.
                 *
                 * Try reloading it after timeout.
                 * See `_loadFragment`
                 */
                case  LOADING_KEY_IO_ERROR:
                    if (getTimer() >= _keyLoadErrorDate) {
                        _loadfragment(_fragCurrent);
                        _loadingState = LOADING_IN_PROGRESS;
                    }
                    break;

                /*
                 * Fragment failed to load.
                 *
                 * Try reloading it after timeout.
                 */
                case LOADING_FRAGMENT_IO_ERROR:
                    if (getTimer() >= _fragLoadErrorDate) {
                        _loadfragment(_fragCurrent);
                        _loadingState = LOADING_IN_PROGRESS;
                    }
                    break;

                /*
                 * Final Fragment has completely loaded.
                 *
                 * We have finished downloading Video. Stop loader.
                 */
                case LOADING_COMPLETED:
                    _hls.dispatchEvent(new HLSEvent(HLSEvent.LAST_VOD_FRAGMENT_LOADED));
                    stop();
                    break;

                /*
                 * Unknown state. Throw error.
                 */
                default:
                    CONFIG::LOGGING {
                        Log.error("FragmentLoader#_checkLoading: invalid loading state: " + _loadingState);
                    }
                    break;
            }
        }

        //
        //
        //
        // PRIVATE FRAGMENT METHODS
        //
        //
        //

        //
        // TODO: REVIEW!
        //
        private function _onFragmentIOError(message : String) : void {
            /* usually, errors happen in two situations :
            - bad networks  : in that case, the second or third reload of URL should fix the issue
                               if loading retry still fails after HLSSettings.fragmentLoadMaxRetry, and
                               if (a) redundant stream(s) is/are available for that level, then try to switch
                               to that redundant stream instead.
            - live playlist : when we are trying to load an out of bound fragments : for example,
            the playlist on webserver is from SN [51-61]
            the one in memory is from SN [50-60], and we are trying to load SN50.
             */
            CONFIG::LOGGING {
                Log.error("I/O Error while loading fragment:" + message);
            }
            if (HLSSettings.fragmentLoadMaxRetry == -1 || _fragRetryCount < HLSSettings.fragmentLoadMaxRetry) {
                _loadingState = LOADING_FRAGMENT_IO_ERROR;
                _fragLoadErrorDate = getTimer() + _fragRetryTimeout;
                CONFIG::LOGGING {
                    Log.warn("retry fragment load in " + _fragRetryTimeout + " ms, count=" + _fragRetryCount);
                }
                /* exponential increase of retry timeout, capped to fragmentLoadMaxRetryTimeout */
                _fragRetryCount++;
                _fragRetryTimeout = Math.min(HLSSettings.fragmentLoadMaxRetryTimeout, 2 * _fragRetryTimeout);
            } else {
                var level : Level = _levels[_fragCurrent.level];
                // if we have redundant streams left for that level, switch to it
                if(level.redundantStreamId < level.redundantStreamsNb) {
                    CONFIG::LOGGING {
                        Log.warn("max load retry reached, switch to redundant stream");
                    }
                    level.redundantStreamId++;
                    _fragRetryCount = 0;
                    _fragRetryTimeout = 1000;
                    _loadingState = LOADING_IDLE;
                } else if(HLSSettings.fragmentLoadSkipAfterMaxRetry == true) {
                    /* check if loaded fragment is not the last one of a live playlist.
                        if it is the case, don't skip to next, as there is no next fragment :-)
                    */
                    if(_hls.type == HLSTypes.LIVE && _fragCurrent.seqnum == level.end_seqnum) {
                        _loadingState = LOADING_FRAGMENT_IO_ERROR;
                        _fragLoadErrorDate = getTimer() + _fragRetryTimeout;
                        CONFIG::LOGGING {
                            Log.warn("max load retry reached on last fragment of live playlist, retrying loading this one...");
                        }
                        /* exponential increase of retry timeout, capped to fragmentLoadMaxRetryTimeout */
                        _fragRetryCount++;
                        _fragRetryTimeout = Math.min(HLSSettings.fragmentLoadMaxRetryTimeout, 2 * _fragRetryTimeout);
                    } else {
                        CONFIG::LOGGING {
                            Log.warn("max fragment load retry reached, skip fragment and load next one");
                        }
                        var tags : Vector.<FLVTag> = tags = new Vector.<FLVTag>();
                        tags.push(_fragCurrent.getSkippedTag());
                        // send skipped FLV tag to StreamBuffer
                        _streamBuffer.appendTags(HLSLoaderTypes.FRAGMENT_MAIN,_fragCurrent.level,_fragCurrent.seqnum ,tags,_fragCurrent.data.pts_start_computed, _fragCurrent.data.pts_start_computed + 1000*_fragCurrent.duration, _fragCurrent.continuity, _fragCurrent.start_time);
                        _fragRetryCount = 0;
                        _fragRetryTimeout = 1000;
                        _fragPrevious = _fragCurrent;
                        _fragSkipping = true;
                        // set fragment first loaded to be true to ensure that we can skip first fragment as well
                        _fragmentFirstLoaded = true;
                        _loadingState = LOADING_IDLE;
                    }
                } else {
                    var hlsError : HLSError = new HLSError(HLSError.FRAGMENT_LOADING_ERROR, _fragCurrent.url, "I/O Error :" + message);
                    _hls.dispatchEvent(new HLSEvent(HLSEvent.ERROR, hlsError));
                }
            }
        }

        //
        //
        //
        //
        //
        //

        private function _loadfirstfragment(position : Number, level : int) : int {

            CONFIG::LOGGING {
                Log.debug("FragmentLoader#_loadfirstfragment(" + position + ", " + level + ")");
            }

            var frag : Fragment = _levels[level].getFragmentBeforePosition(position);
            _hasDiscontinuity = true;

            CONFIG::LOGGING {
                Log.debug("FragmentLoader#_loadfirstfragment: Loading " + frag.seqnum + " of [" + (_levels[level].start_seqnum) + "," + (_levels[level].end_seqnum) + "],level " + level);
            }

            _loadfragment(frag);

            return LOADING_IN_PROGRESS;
        }

        /** Load a fragment **/
        private function _loadnextfragment(level : int, frag_previous : Fragment) : int {
            CONFIG::LOGGING {
                Log.debug("FragmentLoader#_loadnextfragment");
            }
            var new_seqnum : Number;
            var last_seqnum : Number = -1;
            var log_prefix : String;
            var frag : Fragment;

            if (_switchLevel == false || frag_previous.continuity == -1) {
                last_seqnum = frag_previous.seqnum;
            } else {
                // level switch
                // trust program-time : if program-time defined in previous loaded fragment, try to find seqnum matching program-time in new level.
                if (frag_previous.program_date) {
                    last_seqnum = _levels[level].getSeqNumNearestProgramDate(frag_previous.program_date);
                    CONFIG::LOGGING {
                        Log.debug("FragmentLoader#_loadnextfragment: getSeqNumNearestProgramDate(level,date,cc:" + level + "," + frag_previous.program_date + ")=" + last_seqnum);
                    }
                }
                if (last_seqnum == -1) {
                    // if we are here, it means that no program date info is available in the playlist. try to get last seqnum position from PTS + continuity counter
                    last_seqnum = _levels[level].getSeqNumNearestPTS(frag_previous.data.pts_start, frag_previous.continuity);
                    CONFIG::LOGGING {
                        Log.debug("FragmentLoader#_loadnextfragment: getSeqNumNearestPTS(level,pts,cc:" + level + "," + frag_previous.data.pts_start + "," + frag_previous.continuity + ")=" + last_seqnum);
                    }
                    if (last_seqnum == Number.POSITIVE_INFINITY) {
                        /* requested PTS above max PTS of this level:
                         * this case could happen when switching level at the edge of live playlist,
                         * in case playlist of new level is outdated
                         * return 1 to retry loading later.
                         */
                        return LOADING_WAITING_LEVEL_UPDATE;
                    } else if (last_seqnum == -1) {
                        // if we are here, it means that we have no PTS info for this continuity index, we need to do some PTS probing to find the right seqnum
                        /* we need to perform PTS analysis on fragments from same continuity range
                        get first fragment from playlist matching with criteria and load pts */
                        last_seqnum = _levels[level].getFirstSeqNumfromContinuity(frag_previous.continuity);
                        CONFIG::LOGGING {
                            Log.debug("FragmentLoader#_loadnextfragment: getFirstSeqNumfromContinuity(level,cc:" + level + "," + frag_previous.continuity + ")=" + last_seqnum);
                        }
                        if (last_seqnum == Number.NEGATIVE_INFINITY) {
                            // playlist not yet received
                            return LOADING_WAITING_LEVEL_UPDATE;
                        }
                        /* when probing PTS, take previous sequence number as reference if possible */
                        new_seqnum = Math.min(frag_previous.seqnum + 1, _levels[level].getLastSeqNumfromContinuity(frag_previous.continuity));
                        new_seqnum = Math.max(new_seqnum, _levels[level].getFirstSeqNumfromContinuity(frag_previous.continuity));
                        _ptsAnalyzing = true;
                        log_prefix = "analyzing PTS ";
                    } else {
                        // last seqnum found on new level, reset PTS analysis flag
                        _ptsAnalyzing = false;
                    }
                }
            }

            if (_ptsAnalyzing == false) {
                if (last_seqnum == _levels[level].end_seqnum) {
                    // if last segment of level already loaded, return
                    if (_hls.type == HLSTypes.VOD) {
                        // if VOD playlist, loading is completed
                        return LOADING_COMPLETED;
                    } else {
                        // if live playlist, loading is pending on manifest update
                        return LOADING_WAITING_LEVEL_UPDATE;
                    }
                } else {
                    // if previous segment is not the last one, increment it to get new seqnum
                    new_seqnum = last_seqnum + 1;
                    if (new_seqnum < _levels[level].start_seqnum) {
                        // loading stalled ! report to caller
                        return LOADING_STALLED;
                    }
                    frag = _levels[level].getFragmentfromSeqNum(new_seqnum);
                    if (frag == null) {
                        CONFIG::LOGGING {
                            Log.warn("FragmentLoader#_loadnextfragment: error trying to load " + new_seqnum + " of [" + (_levels[level].start_seqnum) + "," + (_levels[level].end_seqnum) + "],level " + level);
                        }
                        return LOADING_WAITING_LEVEL_UPDATE;
                    }
                    // check whether there is a discontinuity between last segment and new segment
                    _hasDiscontinuity = ((frag.continuity != frag_previous.continuity) || _fragSkipping);
                    ;
                    log_prefix = "Loading ";
                }
            }
            frag = _levels[level].getFragmentfromSeqNum(new_seqnum);
            _loadfragment(frag);
            return LOADING_IN_PROGRESS;
        };

        /**
         * Load a Fragment.
         *
         * Loads encryption key synchronously if necessary.
         *
         * @param  {Fragment}
         */
        private function _loadfragment(frag : Fragment) : void {

            CONFIG::LOGGING {
                Log.debug("FragmentLoader#_loadfragment: Will load Fragment levels[" + frag.level + "][" + frag.seqnum + "] from " + frag.url);
            }

            if (_fragmentStream == null) {
                _fragmentStream = new FragmentStream(_hls.stage);
                _fragmentStream.addEventListener(IOErrorEvent.IO_ERROR, _onFragmentStreamError);
                _fragmentStream.addEventListener(SecurityErrorEvent.SECURITY_ERROR, _onFragmentStreamError);
                _fragmentStream.addEventListener(ProgressEvent.PROGRESS, _onFragmentStreamProgress);
                _fragmentStream.addEventListener(Event.COMPLETE, _onFragmentStreamComplete);
            }

            // If there is a DISCONTINUITY or level switch, then force new Demuxer
            if (_hasDiscontinuity || _switchLevel) {
                _demux = null;
            }

            _fragCurrent = frag; // BEWARE STATE

            frag.data.auto_level = _hls.autoLevel;

            /**
             * Called after encryption key was loaded, if necessary.
             *
             * NOTE: This is a JS style callback.
             *
             * @param  {HLSError}
             * @param  {ByteArray}  keyData  -  Encryption key
             */
            var onKeyLoaded : Function = function onKeyLoaded(err : HLSError, keyData : ByteArray) : void {

                // If there was an error loading key then retry
                // Accomplished by bailing - event loop will recall _loadfragment
                if (err) {
                    // Try reloading the key if feature is enabled
                    if (HLSSettings.keyLoadMaxRetry == -1 || _keyRetryCount < HLSSettings.keyLoadMaxRetry) {
                        _loadingState = LOADING_KEY_IO_ERROR;
                        _keyLoadErrorDate = getTimer() + _keyRetryTimeout;
                        CONFIG::LOGGING {
                            Log.warn("FragmentLoader#_loadfragment#onKeyLoaded: Will retry key load in " + _keyRetryTimeout + " ms, count=" + _keyRetryCount);
                        }
                        /* exponential increase of retry timeout, capped to keyLoadMaxRetryTimeout */
                        _keyRetryCount++;
                        _keyRetryTimeout = Math.min(HLSSettings.keyLoadMaxRetryTimeout, 2 * _keyRetryTimeout);
                    } else {
                        var hlsError : HLSError = new HLSError(HLSError.KEY_LOADING_ERROR, _fragCurrent.decrypt_url, "I/O Error");
                        _hls.dispatchEvent(new HLSEvent(HLSEvent.ERROR, err));
                    }
                    return;
                }

                try {
                    // load complete, reset retry counter
                    _keyRetryCount = 0;
                    _keyRetryTimeout = 1000;

                    frag.data.bytes = null;
                    _hls.dispatchEvent(new HLSEvent(HLSEvent.FRAGMENT_LOADING, frag.url));

                    _metrics = _fragmentStream.load(frag, keyData);

                    CONFIG::LOGGING {
                        Log.debug("FragmentLoader#_loadfragment#onKeyLoaded: Loading Fragment levels[" + frag.level + "][" + frag.seqnum + "] from " + frag.url);
                    }
                } catch (error : Error) {
                    var hlsError : HLSError = new HLSError(HLSError.FRAGMENT_LOADING_ERROR, frag.url, error.message);
                    _hls.dispatchEvent(new HLSEvent(HLSEvent.ERROR, hlsError));
                }
            }

            _keyLoader.load(frag.decrypt_url, onKeyLoaded);
        }

        //
        //
        //
        // FragmentStream Event Listeners
        //
        //
        //

        /**
         * When there awas an error downloading Fragment.
         *
         * This is usually:
         * - I/O Error
         * - CORS Error
         *
         * @private
         * @method   _onFragmentStreamError
         * @param    {ErrorEvent}  evt
         */
        private function _onFragmentStreamError(event : ErrorEvent) : void {
            CONFIG::LOGGING {
                Log.error("FragmentLoader#_onFragmentStreamError!");
            }

            // SecurityErrorEvent is a fatal error
            if (event is SecurityErrorEvent) {
                var hlsError : HLSError = new HLSError(
                    HLSError.FRAGMENT_LOADING_CROSSDOMAIN_ERROR,
                    _fragCurrent.url,
                    "Cannot load fragment: crossdomain access denied:" + event.text
                    );
                _hls.dispatchEvent(new HLSEvent(HLSEvent.ERROR, hlsError));
            } else {
                _onFragmentIOError("HTTP status:" + _fragLoadStatus + ",msg:" + event.text);
            }
        };

        /**
         * When a portion of Fragment has been downloaded by FragmentStream.
         *
         * When possible progressed stream is immediately forwarded to Demuxer
         * for parsing, except in the following cases:
         *
         *  - Only a partial Fragment was requested via the
         *    Fragment.byterange_start_offset field.
         *
         * The end-case listener, `onFragmentStreamComplete` will parse either
         * the final portion or the entirety of the Fragment.
         *
         * @private
         * @method   onFragmentStreamProgress
         * @param    {ProgressEvent}  evt
         */
        private function _onFragmentStreamProgress(evt : ProgressEvent) : void {

            _fragCurrent = _fragmentStream.getFragment();

            // If we are loading a partial Fragment then only parse when it has
            // completed loading to desired portion (See onFragmentStreamComplete)
            if (_fragCurrent.byterange_start_offset != -1) {
                return;
            }

            // START PARSING METRICS
            if (_metrics.parsing_begin_time == 0) {
                _metrics.parsing_begin_time = getTimer();
            }

            // Demuxer has not yet been initialized as this is probably first
            // call to onFragmentStreamProgress, but demuxer may also be/remain
            // null due to unknown Fragment type. Probe is synchronous.
            if (_demux == null) {

                _demux = DemuxHelper.probe(
                    _fragCurrent.data.bytes,
                    _levels[_hls.loadLevel],
                    _onDemuxAudioTrackRequested,
                    _onDemuxProgress,
                    _onDemuxComplete,
                    null,
                    _onDemuxVideoMetadata,
                    _onDemuxID3TagFound,
                    false
                    );
            }

            if (_demux) {

                // Demuxer expects the ByteArray delta
                var byteArray : ByteArray = new ByteArray();
                _fragCurrent.data.bytes.readBytes(byteArray, 0, _fragCurrent.data.bytes.length - _fragCurrent.data.bytes.position);
                byteArray.position = 0;

                _demux.append(byteArray);
            }
        }

        /**
         * When the Fragment has been completely downloaded by FragmentStream.
         *
         * If Fragment had a non-start offset then this method sends data to
         * demuxer.
         *
         * @private
         * @method   onFragmentStreamComplete
         * @param    {Event}  evt
         */
        private function _onFragmentStreamComplete(evt : Event) : void {

            _fragCurrent = _fragmentStream.getFragment();

            CONFIG::LOGGING {
                // String used to identify fragment in debug messages
                var fragmentString : String = "Fragment[" + _fragCurrent.level + "][" + _fragCurrent.seqnum + "]";
                Log.debug("FragmentLoader#_onFragmentStreamComplete: " +
                    fragmentString + " Processing Complete");
            }

            // ???: Is this because the Player has been stopped?
            if (_loadingState == LOADING_IDLE) {
                return;
            }

            // Handle partial Fragment loading if necessary
            if (_fragCurrent.byterange_start_offset != -1) {

                // START PARSING METRICS (which were skipped during loading progress)
                if (_metrics.parsing_begin_time == 0) {
                    _metrics.parsing_begin_time = getTimer();
                }

                CONFIG::LOGGING {
                    Log.debug("FragmentLoader#_onFragmentStreamComplete: trim byte range, start/end offset:" +
                        _fragCurrent.byterange_start_offset + "/" +
                        _fragCurrent.byterange_end_offset);
                }

                // Copy only the part of Fragment we care about
                var partialByteArray : ByteArray = new ByteArray();
                _fragCurrent.data.bytes.position = _fragCurrent.byterange_start_offset;
                _fragCurrent.data.bytes.readBytes(partialByteArray, 0, _fragCurrent.byterange_end_offset - _fragCurrent.byterange_start_offset);

                _demux = DemuxHelper.probe(
                    partialByteArray,
                    _levels[_hls.loadLevel],
                    _onDemuxAudioTrackRequested,
                    _onDemuxProgress,
                    _onDemuxComplete,
                    null,
                    _onDemuxVideoMetadata,
                    _onDemuxID3TagFound,
                    false
                    );

                if (_demux) {
                    partialByteArray.position = 0;
                    _demux.append(partialByteArray);
                }
            }

            // If demuxer is still null, then the Fragment type was invalid
            if (_demux == null) {
                CONFIG::LOGGING {
                    Log.error("FragmentLoader#_onFragmentStreamComplete: unknown fragment type");
                    if (HLSSettings.logDebug2) {
                        _fragCurrent.data.bytes.position = 0;
                        var bytes2 : ByteArray = new ByteArray();
                        _fragCurrent.data.bytes.readBytes(bytes2, 0, 512);
                        Log.debug2("FragmentLoader#_onFragmentStreamComplete: frag dump(512 bytes)");
                        Log.debug2(Hex.fromArray(bytes2));
                    }
                }
                _onFragmentIOError("invalid content received");
                _fragCurrent.data.bytes = null;
                return;
            }

            _demux.notifycomplete();
        }

        //
        //
        //
        // Demuxer Callbacks
        //
        //
        //

        /**
         * Called when Demuxer parsed portion of Fragment.
         *
         * @method  _onDemuxProgress
         * @param   {Vector<FLVTag}  tags
         */
        private function _onDemuxProgress(tags : Vector.<FLVTag>) : void {

            _fragCurrent.data.appendTags(tags);

            CONFIG::LOGGING {
                Log.debug2("FragmentLoader#_onDemuxProgress: " + tags.length + " FLVTags extracted and appended to Fragment[" + _fragCurrent.level + "][" + _fragCurrent.seqnum + "]");
            }

            var isFirstFragmentLevelDefined : Boolean =
                HLSSettings.startFromLevel !== -1 ||
                HLSSettings.startFromBitrate !== -1 ||
                _levels.length == 1;

            var previousLevel : int = _fragPrevious !== null ? _fragPrevious.level : _fragCurrent.level;

            // If this is the first _onDemuxProgress call for this Fragment with
            // any video tags having been parsed
            if (!_hasDemuxProgressedOnce && _fragCurrent.data.video_found) {

                _hasDemuxProgressedOnce = true;

                CONFIG::LOGGING {
                    Log.debug("FragmentLoader#_onDemuxProgress: Fragment[" +
                        _fragCurrent.level + "][" + _fragCurrent.seqnum +
                        "] starts with IDR? " + _fragCurrent.data.starts_with_idr +
                        "@" + _fragCurrent.data.pts_min_video_header);
                }

                //
                // Check for IDR at beginning of Fragment on Level switch
                //
                // If Fragment does not start with IDR then async stream same
                // sequence at previous Level.
                //

                var isNonIDRLevelUp : Boolean =
                    _fragCurrent.level > previousLevel &&
                    !_fragCurrent.data.starts_with_idr;

                var isNonIDRLevelDown : Boolean =
                    _fragCurrent.level < previousLevel &&
                    !_fragCurrent.data.starts_with_idr;

                if (isNonIDRLevelUp || isNonIDRLevelDown) {

                    CONFIG::LOGGING {
                        Log.debug("FragmentLoader#_onDemuxProgress: Fragment["
                            + _fragCurrent.level + "][" + _fragCurrent.seqnum +
                            "] does not with start with IDR, but we need it to.");
                    }

                    if ((isNonIDRLevelUp && HLSSettings.recoverFromNonIDRLevelUp) ||
                        (isNonIDRLevelDown && HLSSettings.recoverFromNonIDRLevelDown)) {

                        CONFIG::LOGGING {
                            Log.debug("FragmentLoader#_onDemuxProgress: Fragment[" +
                                _fragCurrent.level + "][" + _fragCurrent.seqnum +
                                "] fetching Fragment[ " +
                                previousLevel + "][" + _fragCurrent.seqnum +
                                "] to recover from non-IDR start");
                        }

                        _emergencyFragment = _levels[previousLevel].getFragmentfromSeqNum(_fragCurrent.seqnum);

                        // Initiate loading of same seqnum Fragment on previous level to find IDR
                        _keyLoader.load(_emergencyFragment.decrypt_url, function (err : HLSError, keyData : ByteArray) : void {
                            _emergencyFragmentDemuxedStream = new FragmentDemuxedStream(_hls.stage);
                            _emergencyFragmentDemuxedStream.load(_emergencyFragment, keyData, null);
                        });
                    }
                }
            }

            //
            // TODO: We have temporarily disabled progressive buffering, as it
            // does not seem to work with IDR recovery. Seems PTS analysis
            // changes expected states. Needs to be debugged further.
            //
            /*
            // Determine if we can do progressively append to StreamBuffer
            if (!mustRecoverFromNonIDRStart && (_fragmentFirstLoaded || (_manifestJustLoaded && isFirstFragmentLevelDefined))) {

                //
                // if audio expected, PTS analysis is done on audio
                // if audio not expected, PTS analysis is done on video
                // the check below ensures that we can compute min/max PTS
                //
                if ((_demux.audioExpected && _fragCurrent.data.audio_found) || (!_demux.audioExpected && _fragCurrent.data.video_found)) {

                    //
                    // TODO: REVIEW THIS CODE
                    //
                    if (_ptsAnalyzing == true) {

                        // in case we are probing PTS, retrieve PTS info and synchronize playlist PTS / sequence number
                        CONFIG::LOGGING {
                            Log.debug("FragmentLoader#_onDemuxProgress: we were analyzing PTS");
                        }

                        _ptsAnalyzing = false;
                        _levels[_hls.loadLevel].updateFragment(
                            _fragCurrent.seqnum,
                            true,
                            _fragCurrent.data.pts_min,
                            _fragCurrent.data.pts_min + _fragCurrent.duration * 1000);

                        // in case we are probing PTS, retrieve PTS info and synchronize playlist PTS / sequence number
                        CONFIG::LOGGING {
                            Log.debug("FragmentLoader#_onDemuxProgress: analyzed PTS " +
                                _fragCurrent.seqnum + " of [" +
                                (_levels[_hls.loadLevel].start_seqnum) + "," +
                                (_levels[_hls.loadLevel].end_seqnum) + "],level " +
                                _hls.loadLevel + " m PTS:" + _fragCurrent.data.pts_min);
                        }

                        //
                        // check if fragment loaded for PTS analysis is the next one
                        // if this is the expected one, then continue
                        // if not, then cancel current fragment loading, next call to loadnextfragment() will load the right seqnum
                        //
                        var next_seqnum : Number = _levels[_hls.loadLevel].getSeqNumNearestPTS(
                            _fragPrevious.data.pts_start,
                            _fragCurrent.continuity
                            ) + 1;

                        CONFIG::LOGGING {
                            Log.debug("FragmentLoader#_onDemuxProgress: analyzed PTS : getSeqNumNearestPTS(level,pts,cc:" +
                                _hls.loadLevel + "," + _fragPrevious.data.pts_start +
                                "," + _fragCurrent.continuity + ")=" + next_seqnum);
                        }

                        if (next_seqnum != _fragCurrent.seqnum) {
                            // stick to same level after PTS analysis
                            _levelNext = _hls.loadLevel;
                            CONFIG::LOGGING {
                                Log.debug("FragmentLoader#_onDemuxProgress: PTS analysis done on " +
                                    _fragCurrent.seqnum + ", matching seqnum is " +
                                    next_seqnum + " of [" +
                                    (_levels[_hls.loadLevel].start_seqnum) + "," +
                                    (_levels[_hls.loadLevel].end_seqnum) +
                                    "], cancel loading and get new one");
                            }
                            _stop_load();
                            _fragCurrent.data.flushTags();
                            _loadingState = LOADING_IDLE;
                            return;
                        }
                    }

                    if (_fragCurrent.data.metadata_tag_injected == false) {
                        _fragCurrent.data.tags.unshift(_fragCurrent.getMetadataTag());
                        if (_hasDiscontinuity) {
                            _fragCurrent.data.tags.unshift(new FLVTag(FLVTag.DISCONTINUITY, _fragCurrent.data.dts_min, _fragCurrent.data.dts_min, false));
                        }
                        _fragCurrent.data.metadata_tag_injected = true;
                    }

                    // provide tags to StreamBuffer
                    _streamBuffer.appendTags(
                        HLSLoaderTypes.FRAGMENT_MAIN,
                        _fragCurrent.level,
                        _fragCurrent.seqnum,
                        _fragCurrent.data.tags,
                        _fragCurrent.data.tag_pts_min,
                        _fragCurrent.data.tag_pts_max + _fragCurrent.data.tag_duration,
                        _fragCurrent.continuity,
                        _fragCurrent.start_time + _fragCurrent.data.tag_pts_start_offset / 1000
                        );

                    _fragCurrent.data.shiftTags();

                    _metrics.parsing_end_time = getTimer();
                    _metrics.size = _fragCurrent.data.bytesLoaded;
                    _metrics.duration = _fragCurrent.data.tag_pts_end_offset;
                    _metrics.id2 = _fragCurrent.data.tags.length;

                    _hls.dispatchEvent(new HLSEvent(HLSEvent.TAGS_LOADED, _metrics));
                    _hasDiscontinuity = false;
                }
            }
            */
        }

        /**
         * Called when Demuxer has finished parsing Fragment.
         *
         * This method is responsible for appending to StreamBuffer if
         * progressive buffering was not possbile.
         *
         * @method  _onDemuxComplete
         */
        private function _onDemuxComplete() : void {

            if (_loadingState == LOADING_IDLE) {
                return;
            }

            //
            // Throw error if Demuxer had problems, but do not bail.
            //
            if ((_demux.audioExpected && !_fragCurrent.data.audio_found) && (_demux.videoExpected && !_fragCurrent.data.video_found)) {
                var parsingError : HLSError = new HLSError(
                    HLSError.FRAGMENT_PARSING_ERROR,
                    _fragCurrent.url,
                    "error parsing fragment, no tag found"
                    );
                _hls.dispatchEvent(new HLSEvent(HLSEvent.ERROR, parsingError));
            }
            CONFIG::LOGGING {
                if (_fragCurrent.data.audio_found) {
                    Log.debug("FragmentLoader#_onDemuxComplete: Fragment[" +
                        _fragCurrent.level + "][" + _fragCurrent.seqnum +
                        "] m/M audio PTS:" + _fragCurrent.data.pts_min_audio +
                        "/" + _fragCurrent.data.pts_max_audio);
                }
                if (_fragCurrent.data.video_found) {
                    Log.debug("FragmentLoader#_onDemuxComplete: Fragment[" +
                        _fragCurrent.level + "][" + _fragCurrent.seqnum +
                        "] m/M video PTS:" + _fragCurrent.data.pts_min_video +
                        "/" + _fragCurrent.data.pts_max_video);

                    if (!_fragCurrent.data.audio_found) {
                    } else {
                        Log.debug("FragmentLoader#_onDemuxComplete: Fragment[" +
                        _fragCurrent.level + "][" + _fragCurrent.seqnum +
                        "] Delta audio/video m/M PTS:" +
                        (_fragCurrent.data.pts_min_video - _fragCurrent.data.pts_min_audio) +
                        "/" + (_fragCurrent.data.pts_max_video - _fragCurrent.data.pts_max_audio));
                    }
                }
            }

            var previousLevel : int = _fragPrevious !== null ? _fragPrevious.level : _fragCurrent.level;

            CONFIG::LOGGING {
                Log.debug("FragmentLoader#_onDemuxComplete: Fragment[" +
                    _fragCurrent.level + "][" + _fragCurrent.seqnum +
                    "] IDR?/Level/PreviousLevel: " + _fragCurrent.data.starts_with_idr
                    + " / " + _fragCurrent.level + " / " + previousLevel);
            }

            var isNonIDRLevelUp : Boolean =
                _fragCurrent.level > previousLevel &&
                !_fragCurrent.data.starts_with_idr;

            var isNonIDRLevelDown : Boolean =
                _fragCurrent.level < previousLevel &&
                !_fragCurrent.data.starts_with_idr;

            //
            // Handle possible IDR Problem here
            //
            if (isNonIDRLevelUp || isNonIDRLevelDown) {

                CONFIG::LOGGING {
                    Log.debug("FragmentLoader#_onDemuxComplete: Fragment[" +
                        _fragCurrent.level + "][" + _fragCurrent.seqnum +
                        "] did not start with IDR, but we'll implement some type of fix.");
                }

                /*
                 * Returns all tags (audio/video) unless it is Video tag that precedes IDR
                 */
                var isNotBadVideoTag : Function = function (tag:FLVTag, index:int, vector:Vector.<FLVTag>):Boolean {
                    return tag.type !== FLVTag.AVC_NALU || tag.pts >= _fragCurrent.data.pts_min_video_header;
                }

                /*
                 * Returns only Video tags that precede an IDR
                 */
                var isGoodVideoTag : Function = function (tag:FLVTag, index:int, vector:Vector.<FLVTag>):Boolean {
                    return tag.type == FLVTag.AVC_NALU && tag.pts < _fragCurrent.data.pts_min_video_header;
                }

                if ((isNonIDRLevelUp   && HLSSettings.recoverFromNonIDRLevelUp) ||
                    (isNonIDRLevelDown && HLSSettings.recoverFromNonIDRLevelDown)) {

                    // Setting isComplete here to prevent any weird race conditions
                    var isComplete = _emergencyFragmentDemuxedStream.complete;
                    _emergencyFragment = _emergencyFragmentDemuxedStream.getFragment();

                    // We have the necessary tags to fix
                    if (_emergencyFragment.data.pts_max_video >= _fragCurrent.data.pts_min_video_header) {
                        CONFIG::LOGGING {
                            Log.debug("FragmentLoader#_onDemuxComplete: Fragment[" +
                                _fragCurrent.level + "][" + _fragCurrent.seqnum + "] Will splice with previous Level for IDR start");
                        }

                        var tagsExceptBadVideo : Vector.<FLVTag> = _fragCurrent.data.tags.filter(isNotBadVideoTag);
                        var goodNonIDRTags : Vector.<FLVTag> = _emergencyFragment.data.tags.filter(isGoodVideoTag);

                        _fragCurrent.data.tags = goodNonIDRTags.concat(tagsExceptBadVideo);

                        _emergencyFragment = null;
                        // TODO: Remove listener?
                        _emergencyFragmentDemuxedStream.close();
                        _emergencyFragmentDemuxedStream.removeEventListener(Event.COMPLETE, _onEmergencyDemuxedStreamComplete);
                        _emergencyFragmentDemuxedStream = null;
                    }
                    else if (!isComplete) { // bail leaving _emergencyFragment callback to recall this callback :(

                        // TODO: Edge where this may not complete in time - do we force buffer or drop fix?
                        _emergencyFragmentDemuxedStream.addEventListener(Event.COMPLETE, _onEmergencyDemuxedStreamComplete);

                        CONFIG::LOGGING {
                            Log.debug("FragmentLoader#_onDemuxComplete: Fragment[" +
                                _fragCurrent.level + "][" + _fragCurrent.seqnum +
                                "] Cannot splice this non-IDR Fragment just yet. bytesLoaded / bytesTotal: " +
                                _emergencyFragment.data.bytesLoaded + ' / ' +
                                _emergencyFragment.data.bytesTotal);
                        }

                        return;
                    }
                    else {

                        CONFIG::LOGGING {
                            Log.error("FragmentLoader#_onDemuxComplete: Fragment[" +
                                _fragCurrent.level + "][" + _fragCurrent.seqnum +
                                "] Emergency Fragment did not have necessary video (???)");
                        }
                    }
                }
                else if (HLSSettings.removePreIDRVideoTags) {
                    CONFIG::LOGGING {
                        Log.debug("FragmentLoader#_onDemuxComplete: Fragment[" +
                            _fragCurrent.level + "][" + _fragCurrent.seqnum + "] Will filter out pre-IDR video tags");
                    }
                    _fragCurrent.data.tags = _fragCurrent.data.tags.filter(isNotBadVideoTag);
                }
            }

            //
            // Finish calculating processing metrics
            // TODO: What else should this include, e.g. fragment fixing?
            //
            _metrics.parsing_end_time = getTimer();
            CONFIG::LOGGING {
                Log.debug("FragmentLoader#_onDemuxComplete: Fragment[" +
                    _fragCurrent.level + "][" + _fragCurrent.seqnum +
                    "] Total Process duration/length/bw: " +
                    _metrics.processing_duration + " / " + _metrics.size + " / " +
                    Math.round(_metrics.bandwidth / 1024) + " kbps");
            }

            //
            // Check if we should immediately adjust level.
            // If this was the first Fragment loaded after the adaptive manifest
            // itself was loaded then we may be using this Fragment simply to be
            // testing bandwidth. Toss it and start Fragment loop again.
            //
            if (_manifestJustLoaded) {
                _manifestJustLoaded = false;
                if (HLSSettings.startFromLevel === -1 && HLSSettings.startFromBitrate === -1 && _levels.length > 1) {
                    // check if we can directly switch to a better bitrate, in case download bandwidth is enough
                    var bestlevel : int = _levelController.getAutoStartBestLevel(_metrics.bandwidth,_metrics.processing_duration, 1000*_fragCurrent.duration);
                    if (bestlevel > _hls.loadLevel) {
                        CONFIG::LOGGING {
                            Log.info("FragmentLoader#_onDemuxComplete: enough download bandwidth, adjust start level from " + _hls.loadLevel + " to " + bestlevel);
                        }
                        // dispatch event for tracking purpose
                        _hls.dispatchEvent(new HLSEvent(HLSEvent.FRAGMENT_LOADED, _metrics));
                        // let's directly jump to the accurate level to improve quality at player start
                        _levelNext = bestlevel;
                        _loadingState = LOADING_IDLE;
                        _switchLevel = true;
                        _demux = null;
                        _hls.dispatchEvent(new HLSEvent(HLSEvent.LEVEL_SWITCH, _hls.loadLevel));
                        // speed up loading of new playlist
                        _timer.start();
                        return;
                    }
                }
            }

            try {

                _switchLevel = false;
                _levelNext = -1;

                CONFIG::LOGGING {
                    Log.debug("FragmentLoader#_onDemuxComplete: Fragment[" +
                        _fragCurrent.level + "][" + _fragCurrent.seqnum +
                        "] completed. m/M PTS:" + _fragCurrent.data.pts_min +
                        "/" + _fragCurrent.data.pts_max);
                }

                // TODO: What type of Fragment do we have if this is false?
                if (_fragCurrent.data.audio_found || _fragCurrent.data.video_found) {

                    // Update Fragment (???)
                    _levels[_hls.loadLevel].updateFragment(_fragCurrent.seqnum, true, _fragCurrent.data.pts_min, _fragCurrent.data.pts_max + _fragCurrent.data.tag_duration);

                    // set pts_start here, it might not be updated directly in updateFragment() if this loaded fragment has been removed from a live playlist
                    _fragCurrent.data.pts_start = _fragCurrent.data.pts_min;

                    _hls.dispatchEvent(new HLSEvent(HLSEvent.PLAYLIST_DURATION_UPDATED, _levels[_hls.loadLevel].duration));

                    // We did not progressively add to StreamBuffer
                    if (_fragCurrent.data.tags.length) {

                        //
                        // If tag vector does not start with a METADATA FLVTag then
                        // prepend one, and if there is DISCONTINUITY then prepend
                        // to that
                        //
                        // NOTE: `getMetadataTag` should really be `createMetadataTag`
                        //
                        if (_fragCurrent.data.metadata_tag_injected == false) {
                            _fragCurrent.data.tags.unshift(_fragCurrent.getMetadataTag());
                            if (_hasDiscontinuity) {
                                _fragCurrent.data.tags.unshift(
                                    new FLVTag(
                                        FLVTag.DISCONTINUITY,
                                        _fragCurrent.data.dts_min,
                                        _fragCurrent.data.dts_min,
                                        false
                                        )
                                    );
                            }
                            _fragCurrent.data.metadata_tag_injected = true;
                        }

                        _streamBuffer.appendTags(
                            HLSLoaderTypes.FRAGMENT_MAIN,
                            _fragCurrent.level,
                            _fragCurrent.seqnum,
                            _fragCurrent.data.tags,
                            _fragCurrent.data.tag_pts_min,
                            _fragCurrent.data.tag_pts_max + _fragCurrent.data.tag_duration,
                            _fragCurrent.continuity,
                            _fragCurrent.start_time + _fragCurrent.data.tag_pts_start_offset / 1000
                            );

                        // Metrics
                        _metrics.duration = _fragCurrent.data.pts_max + _fragCurrent.data.tag_duration - _fragCurrent.data.pts_min;
                        _metrics.id2 = _fragCurrent.data.tags.length;

                        _hls.dispatchEvent(new HLSEvent(HLSEvent.TAGS_LOADED, _metrics));
                        _fragCurrent.data.shiftTags();
                        _hasDiscontinuity = false;

                        _hasDemuxProgressedOnce = false;
                        _emergencyFragment = null;
                    }

                } else {
                    _metrics.duration = _fragCurrent.duration * 1000;
                }

                //
                // Resets states for next fragment and to start load
                //

                _loadingState = LOADING_IDLE;
                _ptsAnalyzing = false;
                _hls.dispatchEvent(new HLSEvent(HLSEvent.FRAGMENT_LOADED, _metrics));
                _fragmentFirstLoaded = true;
                _fragPrevious = _fragCurrent;

            } catch (error : Error) {
                var otherError : HLSError = new HLSError(
                    HLSError.OTHER_ERROR,
                    _fragCurrent.url,
                    error.message
                    );
                _hls.dispatchEvent(new HLSEvent(HLSEvent.ERROR, otherError));
            }

            _timer.start();
        }

        /**
         * Called when Demuxer needs to know which AudioTrack to parse for.
         *
         * @method  _onDemuxAudioTrackRequested
         * @param   {Vector<AudioTrack}  audioTrackList  -  List of AudioTracks
         * @return  {AudioTrack}  -  AudioTrack to parse
         */
        private function _onDemuxAudioTrackRequested(audioTrackList : Vector.<AudioTrack>) : AudioTrack {
            return _audioTrackController.audioTrackSelectionHandler(audioTrackList);
        }

        /**
         * Called when ID3 tags are found.
         *
         * @method  _onDemuxID3TagFound
         * @param   {Vector.<ID3Tag>}  id3_tags  -  ID3 Tags
         */
        private function _onDemuxVideoMetadata(width : uint, height : uint) : void {
            var fragData : FragmentData = _fragCurrent.data;
            if (fragData.video_width == 0) {
                CONFIG::LOGGING {
                    Log.debug("FragmentLoader#_onDemuxVideoMetadata: AVC SPS = " + width + "x" + height);
                }
                fragData.video_width = width;
                fragData.video_height = height;
            }
        }

        /**
         * Called when Video metadata is parsed.
         *
         * Specifically, when Sequence Parameter Set (SPS) is found.
         *
         * @method  _onDemuxVideoMetadata
         * @param   {uint}  width
         * @param   {uint}  height
         */
        private function _onDemuxID3TagFound(id3_tags : Vector.<ID3Tag>) : void {
            _fragCurrent.data.id3_tags = id3_tags;
        }

        /**
         * Called when emergency Fragment has finished loading and demuxing.
         *
         * @method  _onEmergencyDemuxedStreamComplete
         * @param   {Event}  evt
         */
        private function _onEmergencyDemuxedStreamComplete (evt : Event) : void {
            _emergencyFragment = _emergencyFragmentDemuxedStream.getFragment();
            _onDemuxComplete();
        }
    }
}
