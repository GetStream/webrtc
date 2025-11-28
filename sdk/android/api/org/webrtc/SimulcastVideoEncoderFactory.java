/*
 *  Copyright 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

package org.webrtc;

import androidx.annotation.Nullable;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
 
public class SimulcastVideoEncoderFactory implements VideoEncoderFactory {
 
    static native List<VideoCodecInfo> nativeVP9Codecs();
    static native VideoCodecInfo nativeAV1Codec();

    VideoEncoderFactory primary;
    VideoEncoderFactory fallback;
 
    public SimulcastVideoEncoderFactory(VideoEncoderFactory primary, VideoEncoderFactory fallback) {
        this.primary = primary;
        this.fallback = fallback;
    }
 
    @Nullable
    @Override
    public VideoEncoder createEncoder(VideoCodecInfo info) {
        return new SimulcastVideoEncoder(primary, fallback, info);
    }
 
    @Override
    public VideoCodecInfo[] getSupportedCodecs() {
        List<VideoCodecInfo> codecs = new ArrayList<VideoCodecInfo>();
        codecs.addAll(Arrays.asList(primary.getSupportedCodecs()));
        if (fallback != null) {
            codecs.addAll(Arrays.asList(fallback.getSupportedCodecs()));
        }
        codecs.addAll(nativeVP9Codecs());
        codecs.add(nativeAV1Codec());
        
        // Sort codecs: first by codec type (name), then by scalability mode presence
        // Codecs with scalability modes come first within the same type
        // This is needed because webrtc_video_engine.cc removes duplicate encoders from the list before sending them
        // So send the enncoders that have scalability mode ahead
        Collections.sort(codecs, new Comparator<VideoCodecInfo>() {
            @Override
            public int compare(VideoCodecInfo a, VideoCodecInfo b) {
                // First compare by codec name (type)
                int nameComparison = a.name.compareToIgnoreCase(b.name);
                if (nameComparison != 0) {
                    return nameComparison;
                }
                
                // If same codec type, compare by scalability mode presence
                boolean aHasScalabilityModes = a.scalabilityModes != null && !a.scalabilityModes.isEmpty();
                boolean bHasScalabilityModes = b.scalabilityModes != null && !b.scalabilityModes.isEmpty();
                
                // Codecs with scalability modes come first (return negative for a to come before b)
                if (aHasScalabilityModes && !bHasScalabilityModes) {
                    return -1;
                } else if (!aHasScalabilityModes && bHasScalabilityModes) {
                    return 1;
                } else {
                    return 0; // Both have same scalability mode status
                }
            }
        });
        
        return codecs.toArray(new VideoCodecInfo[codecs.size()]);
    }

}
