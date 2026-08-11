package imageproc

import (
	"bytes"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/jpeg"
	"image/png"
	"math"
	"os"

	xdraw "golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

var (
	ErrUnsupportedFormat = errors.New("unsupported image format")
	ErrDecodeFailed      = errors.New("image decode failed")
)

type Spec struct {
	Kind    string
	Width   int
	Height  int
	Fit     string
	Format  string
	Quality int
}

type Output struct {
	Data        []byte
	ContentType string
	Extension   string
}

func (spec Spec) TransformID() string {
	kind := spec.Kind
	if kind == "" {
		kind = "thumb"
	}
	return fmt.Sprintf("%s:%dx%d:%s:%s:q%d",
		kind, spec.Width, spec.Height, spec.Fit, spec.Format, spec.Quality)
}

func TransformFile(path string, spec Spec) (Output, error) {
	file, err := os.Open(path)
	if err != nil {
		return Output{}, fmt.Errorf("open source image: %w", err)
	}
	defer file.Close()

	source, _, err := image.Decode(file)
	if err != nil {
		if errors.Is(err, image.ErrFormat) {
			return Output{}, fmt.Errorf("%w: %v", ErrUnsupportedFormat, err)
		}
		return Output{}, fmt.Errorf("%w: %v", ErrDecodeFailed, err)
	}
	resized, err := contain(source, spec.Width, spec.Height)
	if err != nil {
		return Output{}, err
	}

	var encoded bytes.Buffer
	switch spec.Format {
	case "jpeg":
		opaque := image.NewRGBA(resized.Bounds())
		draw.Draw(opaque, opaque.Bounds(), &image.Uniform{C: color.White}, image.Point{}, draw.Src)
		draw.Draw(opaque, opaque.Bounds(), resized, resized.Bounds().Min, draw.Over)
		if err := jpeg.Encode(&encoded, opaque, &jpeg.Options{Quality: spec.Quality}); err != nil {
			return Output{}, fmt.Errorf("encode JPEG: %w", err)
		}
		return Output{Data: encoded.Bytes(), ContentType: "image/jpeg", Extension: ".jpg"}, nil
	case "png":
		if err := png.Encode(&encoded, resized); err != nil {
			return Output{}, fmt.Errorf("encode PNG: %w", err)
		}
		return Output{Data: encoded.Bytes(), ContentType: "image/png", Extension: ".png"}, nil
	default:
		return Output{}, fmt.Errorf("%w: output format %q", ErrUnsupportedFormat, spec.Format)
	}
}

func contain(source image.Image, maxWidth, maxHeight int) (image.Image, error) {
	bounds := source.Bounds()
	if bounds.Dx() <= 0 || bounds.Dy() <= 0 {
		return nil, fmt.Errorf("source image has invalid dimensions %dx%d", bounds.Dx(), bounds.Dy())
	}
	widthScale := float64(maxWidth) / float64(bounds.Dx())
	heightScale := float64(maxHeight) / float64(bounds.Dy())
	scale := math.Min(widthScale, heightScale)
	if scale > 1 {
		scale = 1
	}
	width := max(1, int(math.Round(float64(bounds.Dx())*scale)))
	height := max(1, int(math.Round(float64(bounds.Dy())*scale)))
	destination := image.NewNRGBA(image.Rect(0, 0, width, height))
	xdraw.CatmullRom.Scale(destination, destination.Bounds(), source, bounds, xdraw.Over, nil)
	return destination, nil
}
