import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.os.Build;
import androidx.annotation.Nullable;
import org.webrtc.EglBase;
import org.webrtc.HardwareVideoDecoderFactory;
import org.webrtc.Logging;
import org.webrtc.MediaCodecUtils;
import org.webrtc.PlatformSoftwareVideoDecoderFactory;
import org.webrtc.SoftwareVideoDecoderFactory;
import org.webrtc.VideoCodecInfo;
import org.webrtc.VideoCodecMimeType;
import org.webrtc.VideoDecoder;
import org.webrtc.VideoDecoderFactory;
import org.webrtc.VideoDecoderFallback;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.function.Predicate;

/** Factory for decoders backed by Android MediaCodec API. */
@SuppressWarnings("deprecation") // API level 16 requires use of deprecated methods.
public class DefaultBlacklistedVideoDecoderFactory implements VideoDecoderFactory {

  private static final String TAG = "DefaultBlacklistedVideoDecoderFactory";

  private static final Predicate<MediaCodecInfo> defaultBlacklistedPredicate =
    new Predicate<MediaCodecInfo>() {
      @Override
      public boolean test(MediaCodecInfo codec) {
        // Use the existing isExynosVP9 method
        if (isExynosVP9(codec)) {
          return true;
        }
        return false;
      }
    };

  private final VideoDecoderFactory hardwareVideoDecoderFactory;
  private final VideoDecoderFactory softwareVideoDecoderFactory;
  private final VideoDecoderFactory platformSoftwareVideoDecoderFactory;
  private final Predicate<MediaCodecInfo> isHardwareDecoderBlacklisted;

  public DefaultBlacklistedVideoDecoderFactory(@Nullable EglBase.Context eglContext) {
    this(eglContext, null);
  }

  public DefaultBlacklistedVideoDecoderFactory(
      @Nullable EglBase.Context eglContext, 
      @Nullable Predicate<MediaCodecInfo> codecBlacklistedPredicate) {
    this.hardwareVideoDecoderFactory = new HardwareVideoDecoderFactory(eglContext);
    this.softwareVideoDecoderFactory = new SoftwareVideoDecoderFactory();
    this.platformSoftwareVideoDecoderFactory = new PlatformSoftwareVideoDecoderFactory(eglContext);
    this.isHardwareDecoderBlacklisted = codecBlacklistedPredicate == null 
      ? defaultBlacklistedPredicate 
      : codecBlacklistedPredicate.and(defaultBlacklistedPredicate);
  }

  @Override
  public VideoDecoder createDecoder(VideoCodecInfo codecType) {
    VideoCodecMimeType type = VideoCodecMimeType.valueOf(codecType.getName());
    MediaCodecInfo info = findCodecForType(type);
    Logging.d(TAG, "[createDecoder] codecType: " + codecType + ", info: " + stringifyCodec(info));

    VideoDecoder softwareDecoder = softwareVideoDecoderFactory.createDecoder(codecType);
    VideoDecoder hardwareDecoder = hardwareVideoDecoderFactory.createDecoder(codecType);
    if (softwareDecoder == null) {
      softwareDecoder = platformSoftwareVideoDecoderFactory.createDecoder(codecType);
    }

    if (isHardwareDecoderBlacklisted.test(info)) {
      Logging.i(TAG, "[createDecoder] hardware decoder is blacklisted: " + stringifyCodec(info));
      return softwareDecoder;
    }

    if (hardwareDecoder != null && softwareDecoder != null) {
      return new VideoDecoderFallback(softwareDecoder, hardwareDecoder);
    } else {
      return hardwareDecoder != null ? hardwareDecoder : softwareDecoder;
    }
  }

  @Override
  public VideoCodecInfo[] getSupportedCodecs() {
    List<VideoCodecInfo> supportedCodecInfos = new ArrayList<>();
    supportedCodecInfos.addAll(Arrays.asList(softwareVideoDecoderFactory.getSupportedCodecs()));
    supportedCodecInfos.addAll(Arrays.asList(hardwareVideoDecoderFactory.getSupportedCodecs()));
    supportedCodecInfos.addAll(Arrays.asList(platformSoftwareVideoDecoderFactory.getSupportedCodecs()));
    return supportedCodecInfos.toArray(new VideoCodecInfo[supportedCodecInfos.size()]);
  }

  @Nullable
  private MediaCodecInfo findCodecForType(VideoCodecMimeType type) {
    for (int i = 0; i < MediaCodecList.getCodecCount(); ++i) {
      MediaCodecInfo info = null;
      try {
        info = MediaCodecList.getCodecInfoAt(i);
      } catch (IllegalArgumentException e) {
        Logging.e(TAG, "[findCodecForType] cannot retrieve decoder codec info", e);
      }

      if (info == null || info.isEncoder()) {
        continue;
      }

      if (isSupportedCodec(info, type)) {
        return info;
      }
    }
    return null; // No support for this type.
  }

  // Returns true if the given MediaCodecInfo indicates a supported encoder for the given type.
  private boolean isSupportedCodec(MediaCodecInfo info, VideoCodecMimeType type) {
    if (!MediaCodecUtils.codecSupportsType(info, type)) {
      return false;
    }
    // Check for a supported color format.
    if (MediaCodecUtils.selectColorFormat(
        MediaCodecUtils.DECODER_COLOR_FORMATS, info.getCapabilitiesForType(type.mimeType()))
        == null) {
      return false;
    }
    return isCodecAllowed(info);
  }

  private boolean isCodecAllowed(MediaCodecInfo info) {
    return MediaCodecUtils.isHardwareAccelerated(info) || MediaCodecUtils.isSoftwareOnly(info);
  }

  private static boolean isExynosVP9(MediaCodecInfo codec) {
    final String codecName = codec.getName().toLowerCase();
    return !codec.isEncoder() && codecName.contains("exynos") && codecName.contains("vp9");
  }

  private static String stringifyCodec(MediaCodecInfo codec) {
    if (codec == null) {
      return "null";
    }
    return "MediaCodecInfo(name=" + codec.getName() + ", isEncoder=" + codec.isEncoder() + ")";
  }
}
