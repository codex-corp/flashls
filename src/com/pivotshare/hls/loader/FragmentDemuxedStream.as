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
    import com.pivotshare.hls.loader.FragmentStream;
    import org.mangui.hls.constant.HLSLoaderTypes;
    import org.mangui.hls.demux.Demuxer;
    import org.mangui.hls.demux.DemuxHelper;
    import org.mangui.hls.demux.ID3Tag;
    import org.mangui.hls.event.HLSError;
    import org.mangui.hls.event.HLSEvent;
    import org.mangui.hls.event.HLSLoadMetrics;
    import org.mangui.hls.flv.FLVTag;
    import org.mangui.hls.HLS;
    import org.mangui.hls.model.AudioTrack;
    import org.mangui.hls.model.Fragment;
    import org.mangui.hls.model.FragmentData;
    import org.mangui.hls.utils.AES;

    CONFIG::LOGGING {
        import org.mangui.hls.utils.Log;
        import org.mangui.hls.utils.Hex;
    }

    /**
     * HLS Fragment Demuxed Streamer.
     * Tries to parallel URLStream design pattern, but is incomplete.
     *
     * This class encapsulates Demuxing, but in an inefficient way. This is not
     * meant to be performant for sequential Fragments in play.
     *
     * @class    FragmentDemuxedStream
     * @extends  EventDispatcher
     * @author   HGPA
     */
    public class FragmentDemuxedStream extends EventDispatcher {

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
        private var _fragmentStream : FragmentStream;

        /*
         * Metrics for this stream.
         */
        private var _metrics : HLSLoadMetrics;

        /*
         * Demuxer needed for this Fragment.
         */
        private var _demux : Demuxer;

        /*
         * Options for streaming and demuxing.
         */
        private var _options : Object;

        //
        //
        //
        // Public Methods
        //
        //
        //

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
        public function FragmentDemuxedStream(displayObject : DisplayObject) : void {
            _displayObject = displayObject;
            _fragment = null;
            _fragmentStream = null;
            _metrics = null;
            _demux = null;
            _options = new Object();
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
            if (_fragmentStream) {
                _fragmentStream.close();
            }

            if (_demux) {
                _demux.cancel();
                _demux = null;
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
        public function load(fragment : Fragment, key : ByteArray, options : Object) : HLSLoadMetrics {

            _options = options;

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

            _fragmentStream = new FragmentStream(_displayObject);

            _fragmentStream.addEventListener(IOErrorEvent.IO_ERROR, onStreamError);
            _fragmentStream.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onStreamError);
            _fragmentStream.addEventListener(ProgressEvent.PROGRESS, onStreamProgress);
            _fragmentStream.addEventListener(Event.COMPLETE, onStreamComplete);

            CONFIG::LOGGING {
                var fragmentString : String = "Fragment[" + _fragment.level + "][" + _fragment.seqnum + "]";
                Log.debug("FragmentDemuxedStream#load: " + fragmentString);
            }

            _metrics = _fragmentStream.load(_fragment, key);

            return _metrics;
        }

        //
        //
        //
        // FragmentStream Event Listeners
        //
        //
        //

        /**
         *
         * @method  onFragmentStreamProgress
         * @param   {ProgressEvent}  evt
         */
        private function onStreamProgress(evt : ProgressEvent) : void {

            _fragment = _fragmentStream.getFragment();

            CONFIG::LOGGING {
                var fragmentString : String = "Fragment[" + _fragment.level + "][" + _fragment.seqnum + "]";
                Log.debug2("FragmentDemuxedStream#onStreamProgress: " +
                    fragmentString + " Progress - " + evt.bytesLoaded + " of " + evt.bytesTotal);

                Log.debug2("FragmentDemuxedStream#onStreamProgress: " +
                    fragmentString + " Fragment status - bytes.position / bytes.length / bytesLoaded " +
                    _fragment.data.bytes.position + " / " +
                    _fragment.data.bytes.length + " / " +
                    _fragment.data.bytesLoaded);
            }

            // If we are loading a partial Fragment then only parse when it has
            // completed loading to desired portion (See onFragmentStreamComplete)
            /*
            if (fragment.byterange_start_offset != -1) {
                return;
            }
            */

            // START PARSING METRICS
            if (_metrics.parsing_begin_time == 0) {
                _metrics.parsing_begin_time = getTimer();
            }

            // Demuxer has not yet been initialized as this is probably first
            // call to onFragmentStreamProgress, but demuxer may also be/remain
            // null due to unknown Fragment type. Probe is synchronous.
            if (_demux == null) {

                // It is possible we have run onFragmentStreamProgress before
                // without having sufficient data to probe
                //bytes.position = bytes.length;
                //bytes.writeBytes(byteArray);
                //byteArray = bytes;
                CONFIG::LOGGING {
                    var fragmentString : String = "Fragment[" + _fragment.level + "][" + _fragment.seqnum + "]";
                    Log.debug2("FragmentDemuxedStream#onStreamProgress: Need a Demuxer for " + fragmentString);
                }

                _demux = DemuxHelper.probe(
                    _fragment.data.bytes,
                    null,
                    _onDemuxAudioTrackRequested,
                    _onDemuxProgress,
                    _onDemuxComplete,
                    _onDemuxVideoMetadata,
                    _onDemuxID3TagFound,
                    false
                    );
            }

            if (_demux) {

                // Demuxer expects the ByteArray delta
                var byteArray : ByteArray = new ByteArray();
                _fragment.data.bytes.readBytes(byteArray, 0, _fragment.data.bytes.length - _fragment.data.bytes.position);
                byteArray.position = 0;

                _demux.append(byteArray);
            }
        }

        /**
         * Called when FragmentStream completes.
         *
         * @method  onStreamComplete
         * @param   {Event}  evt
         */
        private function onStreamComplete(evt : Event) : void {

            // If demuxer is still null, then the Fragment type was invalid
            if (_demux == null) {
                CONFIG::LOGGING {
                    Log.error("FragmentDemuxedStream#onStreamComplete: unknown fragment type");
                    _fragment.data.bytes.position = 0;
                    var bytes2 : ByteArray = new ByteArray();
                    _fragment.data.bytes.readBytes(bytes2, 0, 512);
                    Log.debug2("FragmentDemuxedStream#onStreamComplete: frag dump(512 bytes)");
                    Log.debug2(Hex.fromArray(bytes2));
                }

                var err : ErrorEvent = new ErrorEvent(
                    ErrorEvent.ERROR,
                    false,
                    false,
                    "Unknown Fragment Type"
                    );

                dispatchEvent(err);

            } else {
                _demux.notifycomplete();
            }
        }

        /**
         * Called when FragmentStream has errored.
         *
         * @method  onStreamError
         * @param   {ProgressEvent}  evt
         */
        private function onStreamError(evt : ErrorEvent) : void {
            CONFIG::LOGGING {
                Log.error("FragmentDemuxedStream#onStreamError: " + evt.text);
            }
            dispatchEvent(evt);
        }

        //
        //
        //
        // Demuxer Callbacks
        //
        //
        //

        /**
         * Called when Demuxer needs to know which AudioTrack to parse for.
         *
         * FIXME: This callback simply returns the first audio track!
         * We need to pass this class the appropriate callback propogated from
         * UI layer. Yuck.
         *
         * @method  _onDemuxAudioTrackRequested
         * @param   {Vector<AudioTrack}  audioTrackList  -  List of AudioTracks
         * @return  {AudioTrack}  -  AudioTrack to parse
         */
        private function _onDemuxAudioTrackRequested(audioTrackList : Vector.<AudioTrack>) : AudioTrack {
            if (audioTrackList.length > 0) {
                return audioTrackList[0];
            } else {
                return null;
            }
        }

        /**
         * Called when Demuxer parsed portion of Fragment.
         *
         * @method  _onDemuxProgress
         * @param   {Vector<FLVTag}  tags
         */
        private function _onDemuxProgress(tags : Vector.<FLVTag>) : void {
            CONFIG::LOGGING {
                Log.debug2("FragmentDemuxedStream#_onDemuxProgress");
            }

            _fragment.data.appendTags(tags);

            // TODO: Options to parse only portion of Fragment

            // FIXME: bytesLoaded and bytesTotal represent stats of the current
            // FragmentStream, not Demuxer, which is no longer bytes-relative.
            // What should we define here?
            var progressEvent : ProgressEvent = new ProgressEvent(
                ProgressEvent.PROGRESS,
                false,
                false,
                _fragment.data.bytes.length, // bytesLoaded
                _fragment.data.bytesTotal    // bytesTotal
                );

            dispatchEvent(progressEvent);
        };

        /**
         * Called when Demuxer has finished parsing Fragment.
         *
         * @method  _onDemuxComplete
         */
        private function _onDemuxComplete() : void {
            CONFIG::LOGGING {
                Log.debug2("FragmentDemuxedStream#_onDemuxComplete");
            }

            _metrics.parsing_end_time = getTimer();

            var completeEvent : Event = new ProgressEvent(Event.COMPLETE);
            dispatchEvent(completeEvent);
        };

        /**
         * Called when Video metadata is parsed.
         *
         * Specifically, when Sequence Parameter Set (SPS) is found.
         *
         * @method  _onDemuxVideoMetadata
         * @param   {uint}  width
         * @param   {uint}  height
         */
        private function _onDemuxVideoMetadata(width : uint, height : uint) : void {
            if (_fragment.data.video_width == 0) {
                CONFIG::LOGGING {
                    Log.debug2("FragmentDemuxedStream#_onDemuxVideoMetadata: AVC SPS = " + width + "x" + height);
                }
                _fragment.data.video_width = width;
                _fragment.data.video_height = height;
            }
        }

        /**
         * Called when ID3 tags are found.
         *
         * @method  _onDemuxID3TagFound
         * @param   {Vector.<ID3Tag>}  id3_tags  -  ID3 Tags
         */
        private function _onDemuxID3TagFound(id3_tags : Vector.<ID3Tag>) : void {
            _fragment.data.id3_tags = id3_tags;
        }

    }
}
