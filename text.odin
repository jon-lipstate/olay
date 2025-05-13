package olay

import hinter "../runic/hinter"
import shaper "../runic/shaper"
import ttf "../runic/ttf"

import "core:fmt"

Text_Data :: struct {
	text:           string,
	font_id:        u16,
	font_size:      u16,
	letter_spacing: u16,
	line_height:    u16,
	text_color:     Color,
	text_alignment: Text_Alignment,
	wrap_mode:      Wrap_Mode,
	buffer:         ^shaper.Shaping_Buffer,
	measured_lines: [dynamic]Wrapped_Text_Line, // Cached measurement
}

create_text_element :: proc(
	parent: ^Element,
	id: string,
	text: string,
	font_id: shaper.Font_ID,
	engine: ^shaper.Engine,
	font_size: u16 = 16,
	color: Color = {0, 0, 0, 1},
) -> ^Element {
	element := push_element(parent, id)

	// Default text element configuration
	element.constraints.x.mode = .Fit
	element.constraints.y.mode = .Fit

	// Create text data
	text_data := new(Text_Data)
	text_data.text = text
	text_data.font_id = u16(font_id)
	// text_data.engine = engine
	text_data.font_size = font_size
	text_data.text_color = color

	// Shape the text
	shaped_text, ok := shape_text(engine, font_id, text)
	if !ok {
		fmt.eprintln("Failed to shape text:", text)
		free(text_data)
		return element
	}

	text_data.buffer = shaped_text
	element.data = text_data

	return element
}
