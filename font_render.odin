package olay

import hinter "../runic/hinter"
import shaper "../runic/shaper"
import ttf "../runic/ttf"
import "core:fmt"
import "core:strings"
import "core:time"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

font_vtx_shader := transmute(string)#load("./shaders/font.vert")
font_frag_shader := transmute(string)#load("./shaders/font.frag")
background_vtx_shader := transmute(string)#load("./shaders/background.frag")
background_frag_shader := transmute(string)#load("./shaders/background.frag")


compile_shader_program :: proc(
	vertex_source, fragment_source: string,
) -> (
	program: u32,
	ok: bool,
) {
	vertex_shader := gl.CreateShader(gl.VERTEX_SHADER)
	defer gl.DeleteShader(vertex_shader)

	vertex_source_cstr := strings.clone_to_cstring(vertex_source)
	defer delete(vertex_source_cstr)
	gl.ShaderSource(vertex_shader, 1, &vertex_source_cstr, nil)
	gl.CompileShader(vertex_shader)

	// Check compilation
	success: i32
	gl.GetShaderiv(vertex_shader, gl.COMPILE_STATUS, &success)
	if success == 0 {
		log_buffer: [512]u8
		gl.GetShaderInfoLog(vertex_shader, 512, nil, &log_buffer[0])
		fmt.eprintln("Vertex shader compilation failed:", string(log_buffer[:]))
		return 0, false
	}

	// Similar for fragment shader
	fragment_shader := gl.CreateShader(gl.FRAGMENT_SHADER)
	defer gl.DeleteShader(fragment_shader)

	fragment_source_cstr := strings.clone_to_cstring(fragment_source)
	defer delete(fragment_source_cstr)
	gl.ShaderSource(fragment_shader, 1, &fragment_source_cstr, nil)
	gl.CompileShader(fragment_shader)

	gl.GetShaderiv(fragment_shader, gl.COMPILE_STATUS, &success)
	if success == 0 {
		log_buffer: [512]u8
		gl.GetShaderInfoLog(fragment_shader, 512, nil, &log_buffer[0])
		fmt.eprintln("Fragment shader compilation failed:", string(log_buffer[:]))
		return 0, false
	}

	// Link program
	program = gl.CreateProgram()
	gl.AttachShader(program, vertex_shader)
	gl.AttachShader(program, fragment_shader)
	gl.LinkProgram(program)

	gl.GetProgramiv(program, gl.LINK_STATUS, &success)
	if success == 0 {
		log_buffer: [512]u8
		gl.GetProgramInfoLog(program, 512, nil, &log_buffer[0])
		fmt.eprintln("Shader program linking failed:", string(log_buffer[:]))
		gl.DeleteProgram(program)
		return 0, false
	}

	return program, true
}

Buffer_Vertex :: struct {
	x, y, u, v:   f32,
	buffer_index: i32,
}

Buffer_Glyph :: struct {
	start, count: i32,
}

Buffer_Curve :: struct {
	x0, y0, x1, y1, x2, y2: f32,
}


Glyph_Key :: struct {
	glyph:   ttf.Glyph,
	font_id: u32,
	size:    u16,
}

Glyph_Cache_Entry :: struct {
	buffer_index: i32, // Index into the buffer_glyphs array
	curve_start:  i32, // Start index in buffer_curves
	curve_count:  i32, // Number of curves
	metrics:      ttf.Glyph_Metrics,
	last_used:    time.Time, // For possible LRU cache eviction
}

Glyph_Cache :: struct {
	entries:          map[Glyph_Key]Glyph_Cache_Entry,
	buffer_glyphs:    [dynamic]Buffer_Glyph,
	buffer_curves:    [dynamic]Buffer_Curve,

	// OpenGL buffer IDs
	glyph_texture_id: u32,
	curve_texture_id: u32,
	glyph_buffer_id:  u32,
	curve_buffer_id:  u32,

	// For curve storage
	next_curve_index: i32,

	// For managing the cache
	dirty:            bool, // Indicates if buffers need to be re-uploaded
}

init_glyph_cache :: proc(cache: ^Glyph_Cache) {
	cache.entries = make(map[Glyph_Key]Glyph_Cache_Entry)
	cache.buffer_glyphs = make([dynamic]Buffer_Glyph)
	cache.buffer_curves = make([dynamic]Buffer_Curve)
	cache.next_curve_index = 0

	// Generate the necessary OpenGL buffer and texture objects
	gl.GenTextures(1, &cache.glyph_texture_id)
	gl.GenTextures(1, &cache.curve_texture_id)
	gl.GenBuffers(1, &cache.glyph_buffer_id)
	gl.GenBuffers(1, &cache.curve_buffer_id)

	cache.dirty = true
}

destroy_glyph_cache :: proc(cache: ^Glyph_Cache) {
	delete(cache.entries)
	delete(cache.buffer_glyphs)
	delete(cache.buffer_curves)

	gl.DeleteTextures(1, &cache.glyph_texture_id)
	gl.DeleteTextures(1, &cache.curve_texture_id)
	gl.DeleteBuffers(1, &cache.glyph_buffer_id)
	gl.DeleteBuffers(1, &cache.curve_buffer_id)
}

// This function processes a glyph and adds it to the cache
get_or_cache_glyph :: proc(
	cache: ^Glyph_Cache,
	font: ^ttf.Font,
	glyph_id: ttf.Glyph,
	font_id: u32,
	size: u16,
) -> (
	entry: Glyph_Cache_Entry,
	ok: bool,
) {
	key := Glyph_Key{glyph_id, font_id, size}

	// Check if already in cache
	if entry, found := cache.entries[key]; found {
		entry.last_used = time.now()
		cache.entries[key] = entry
		return entry, true
	}

	// Not in cache, need to process this glyph
	glyf, has_glyf := ttf.get_table(font, .glyf, ttf.load_glyf_table, ttf.Glyf_Table)
	if !has_glyf {
		return {}, false
	}

	// Get metrics for this glyph
	metrics, mok := ttf.get_metrics(font, glyph_id)
	if !mok {
		return {}, false
	}

	// Extract glyph outline
	extracted, ook := ttf.extract_glyph(glyf, glyph_id)
	if !ook {
		return {}, false
	}

	// Add a new entry to the buffer_glyphs array
	buffer_index := len(cache.buffer_glyphs)
	curve_start := cache.next_curve_index
	curve_count: i32 = 0

	// Process the extracted glyph based on its type
	curve_count = process_extracted_glyph(cache, font, glyf, extracted, font_id, size)

	// Add the glyph entry to the buffer
	append(&cache.buffer_glyphs, Buffer_Glyph{start = curve_start, count = curve_count})

	cache.next_curve_index += curve_count

	// Create and store the cache entry
	new_entry := Glyph_Cache_Entry {
		buffer_index = i32(buffer_index),
		curve_start  = curve_start,
		curve_count  = curve_count,
		metrics      = metrics,
		last_used    = time.now(),
	}

	cache.entries[key] = new_entry
	cache.dirty = true

	return new_entry, true
}

// Helper function to process an extracted glyph and add its curves to the cache
process_extracted_glyph :: proc(
	cache: ^Glyph_Cache,
	font: ^ttf.Font,
	glyf: ^ttf.Glyf_Table,
	extracted: ttf.Extracted_Glyph,
	font_id: u32,
	size: u16,
) -> (
	curve_count: i32,
) {
	curve_count = 0

	#partial switch extracted in extracted {
	case ttf.Extracted_Simple_Glyph:
		// Process simple glyph directly
		curve_count = process_simple_glyph(cache, extracted)

	case ttf.Extracted_Compound_Glyph:
		// For compound glyphs, recursively process each component
		for component in extracted.components {
			// Extract the component glyph
			comp_extracted, ok := ttf.extract_glyph(glyf, component.glyph_id)
			if !ok {
				continue
			}

			// Process the component
			// Note: We need to apply the component's transform to all points
			// This would require creating transformed copies of the points
			comp_curve_count := process_transformed_glyph(
				cache,
				comp_extracted,
				component.transform,
			)

			curve_count += comp_curve_count
		}
	}

	return curve_count
}

// Process a simple glyph and add its curves to the cache
process_simple_glyph :: proc(
	cache: ^Glyph_Cache,
	glyph: ttf.Extracted_Simple_Glyph,
) -> (
	curve_count: i32,
) {
	curve_count = 0

	// Process each contour
	point_index := 0
	for contour_idx := 0; contour_idx < len(glyph.contour_endpoints); contour_idx += 1 {
		contour_end := int(glyph.contour_endpoints[contour_idx])
		start_point_index := point_index

		// Process points in this contour
		for point_index <= contour_end {
			// Handle point triplets to create quadratic bezier curves
			p0 := glyph.points[point_index]
			on0 := glyph.on_curve[point_index]
			point_index += 1

			if point_index > contour_end {
				// Connect back to the first point
				p1 := glyph.points[start_point_index]
				on1 := glyph.on_curve[start_point_index]

				if on0 && on1 {
					// Line segment - convert to quadratic bezier with midpoint
					mid_x := (f32(p0[0]) + f32(p1[0])) / 2.0
					mid_y := (f32(p0[1]) + f32(p1[1])) / 2.0

					append(
						&cache.buffer_curves,
						Buffer_Curve {
							x0 = f32(p0[0]),
							y0 = f32(p0[1]),
							x1 = mid_x,
							y1 = mid_y,
							x2 = f32(p1[0]),
							y2 = f32(p1[1]),
						},
					)
					curve_count += 1
				} else if !on0 && on1 {
					// Quadratic bezier curve (off-curve control point)
					append(
						&cache.buffer_curves,
						Buffer_Curve {
							x0 = f32(glyph.points[point_index - 2][0]),
							y0 = f32(glyph.points[point_index - 2][1]),
							x1 = f32(p0[0]),
							y1 = f32(p0[1]),
							x2 = f32(p1[0]),
							y2 = f32(p1[1]),
						},
					)
					curve_count += 1
				}
				break
			}

			p1 := glyph.points[point_index]
			on1 := glyph.on_curve[point_index]

			if on0 && on1 {
				// Line segment - convert to quadratic bezier with midpoint
				mid_x := (f32(p0[0]) + f32(p1[0])) / 2.0
				mid_y := (f32(p0[1]) + f32(p1[1])) / 2.0

				append(
					&cache.buffer_curves,
					Buffer_Curve {
						x0 = f32(p0[0]),
						y0 = f32(p0[1]),
						x1 = mid_x,
						y1 = mid_y,
						x2 = f32(p1[0]),
						y2 = f32(p1[1]),
					},
				)
				curve_count += 1
				point_index -= 1 // Step back so p1 becomes p0 in the next iteration
			} else if on0 && !on1 {
				// First point is on-curve, second is off-curve
				// Need to look ahead to the next point
				if point_index + 1 <= contour_end {
					p2 := glyph.points[point_index + 1]
					on2 := glyph.on_curve[point_index + 1]

					if on2 {
						// Off-curve point is a control point for quadratic bezier
						append(
							&cache.buffer_curves,
							Buffer_Curve {
								x0 = f32(p0[0]),
								y0 = f32(p0[1]),
								x1 = f32(p1[0]),
								y1 = f32(p1[1]),
								x2 = f32(p2[0]),
								y2 = f32(p2[1]),
							},
						)
						curve_count += 1
						point_index += 1 // Skip ahead
					} else {
						// Two consecutive off-curve points
						// Insert virtual on-curve point at midpoint
						mid_x := (f32(p1[0]) + f32(p2[0])) / 2.0
						mid_y := (f32(p1[1]) + f32(p2[1])) / 2.0

						append(
							&cache.buffer_curves,
							Buffer_Curve {
								x0 = f32(p0[0]),
								y0 = f32(p0[1]),
								x1 = f32(p1[0]),
								y1 = f32(p1[1]),
								x2 = mid_x,
								y2 = mid_y,
							},
						)
						curve_count += 1

						// Use current off-curve point and midpoint for next iteration
						p0 = [2]i16{i16(mid_x), i16(mid_y)}
						on0 = true
						continue // Don't increment point_index
					}
				} else {
					// Last point in contour is off-curve
					// Connect to first point with quadratic bezier
					p2 := glyph.points[start_point_index]

					append(
						&cache.buffer_curves,
						Buffer_Curve {
							x0 = f32(p0[0]),
							y0 = f32(p0[1]),
							x1 = f32(p1[0]),
							y1 = f32(p1[1]),
							x2 = f32(p2[0]),
							y2 = f32(p2[1]),
						},
					)
					curve_count += 1
				}
			} else if !on0 && !on1 {
				// Two consecutive off-curve points
				// Insert virtual on-curve point at midpoint
				mid_x := (f32(p0[0]) + f32(p1[0])) / 2.0
				mid_y := (f32(p0[1]) + f32(p1[1])) / 2.0

				// Use previous point, current off-curve point and midpoint
				append(
					&cache.buffer_curves,
					Buffer_Curve {
						x0 = f32(glyph.points[point_index - 2][0]),
						y0 = f32(glyph.points[point_index - 2][1]),
						x1 = f32(p0[0]),
						y1 = f32(p0[1]),
						x2 = mid_x,
						y2 = mid_y,
					},
				)
				curve_count += 1

				// Use midpoint as the new starting point for next iteration
				p0 = [2]i16{i16(mid_x), i16(mid_y)}
				on0 = true
				continue // Don't increment point_index
			} else if !on0 && on1 {
				// Off-curve control point
				append(
					&cache.buffer_curves,
					Buffer_Curve {
						x0 = f32(glyph.points[point_index - 2][0]),
						y0 = f32(glyph.points[point_index - 2][1]),
						x1 = f32(p0[0]),
						y1 = f32(p0[1]),
						x2 = f32(p1[0]),
						y2 = f32(p1[1]),
					},
				)
				curve_count += 1
			}

			point_index += 1
		}
	}

	return curve_count
}

// Process a glyph with a transformation applied
process_transformed_glyph :: proc(
	cache: ^Glyph_Cache,
	extracted: ttf.Extracted_Glyph,
	transform: matrix[2, 3]f32,
) -> (
	curve_count: i32,
) {
	// For compound glyphs, we need to apply the transformation to all points
	// This function is a placeholder - you would need to implement a proper
	// transformation of the extracted glyph

	// Simple implementation that just delegates to process_simple_glyph
	// but applies the transformation to the points first

	#partial switch extracted in extracted {
	case ttf.Extracted_Simple_Glyph:
		// Create a transformed copy of the glyph
		transformed := extracted

		// Apply transform to all points
		for i := 0; i < len(transformed.points); i += 1 {
			x := f32(transformed.points[i][0])
			y := f32(transformed.points[i][1])

			// Apply transformation matrix
			new_x := transform[0, 0] * x + transform[0, 1] * y + transform[0, 2]
			new_y := transform[1, 0] * x + transform[1, 1] * y + transform[1, 2]

			transformed.points[i][0] = i16(new_x)
			transformed.points[i][1] = i16(new_y)
		}

		// Process the transformed simple glyph
		curve_count = process_simple_glyph(cache, transformed)

	case ttf.Extracted_Compound_Glyph:
		// This is a compound of a compound - more complex!
		// Needs recursive handling with transform composition
		// This is a simplified placeholder
		for component in extracted.components {
			// Compose transformations
			composed_transform: matrix[2, 3]f32

			// Matrix multiplication for composition
			composed_transform[0, 0] =
				transform[0, 0] * component.transform[0, 0] +
				transform[0, 1] * component.transform[1, 0]
			composed_transform[0, 1] =
				transform[0, 0] * component.transform[0, 1] +
				transform[0, 1] * component.transform[1, 1]
			composed_transform[0, 2] =
				transform[0, 0] * component.transform[0, 2] +
				transform[0, 1] * component.transform[1, 2] +
				transform[0, 2]

			composed_transform[1, 0] =
				transform[1, 0] * component.transform[0, 0] +
				transform[1, 1] * component.transform[1, 0]
			composed_transform[1, 1] =
				transform[1, 0] * component.transform[0, 1] +
				transform[1, 1] * component.transform[1, 1]
			composed_transform[1, 2] =
				transform[1, 0] * component.transform[0, 2] +
				transform[1, 1] * component.transform[1, 2] +
				transform[1, 2]

			// Extract and process this component with the composed transform
			// Note: This is a recursive operation that would need to be implemented
			// For simplicity, this example doesn't implement it fully
		}
	}

	return curve_count
}

// Call this whenever the cache has been modified to update GPU buffers
update_glyph_cache_buffers :: proc(cache: ^Glyph_Cache) {
	if !cache.dirty {
		return
	}

	// Upload glyph buffer
	gl.BindBuffer(gl.TEXTURE_BUFFER, cache.glyph_buffer_id)
	gl.BufferData(
		gl.TEXTURE_BUFFER,
		size_of(Buffer_Glyph) * len(cache.buffer_glyphs),
		raw_data(cache.buffer_glyphs),
		gl.STATIC_DRAW,
	)

	gl.BindTexture(gl.TEXTURE_BUFFER, cache.glyph_texture_id)
	gl.TexBuffer(gl.TEXTURE_BUFFER, gl.RG32I, cache.glyph_buffer_id)

	// Upload curve buffer
	gl.BindBuffer(gl.TEXTURE_BUFFER, cache.curve_buffer_id)
	gl.BufferData(
		gl.TEXTURE_BUFFER,
		size_of(Buffer_Curve) * len(cache.buffer_curves),
		raw_data(cache.buffer_curves),
		gl.STATIC_DRAW,
	)

	gl.BindTexture(gl.TEXTURE_BUFFER, cache.curve_texture_id)
	gl.TexBuffer(gl.TEXTURE_BUFFER, gl.RG32F, cache.curve_buffer_id)

	cache.dirty = false
}


Text_GPU_Data :: struct {
	vao:          u32, // Vertex Array Object
	vbo:          u32, // Vertex Buffer Object
	ebo:          u32, // Element Buffer Object
	vertex_count: i32, // Number of vertices
	index_count:  i32, // Number of indices
	initialized:  bool, // Has this been initialized
}

// Corrected version using proper field names
prepare_text_gpu_data :: proc(
	text_data: ^Text_Data,
	font: ^ttf.Font,
	cache: ^Glyph_Cache,
	position: [2]f32,
) {
	buffer := text_data.buffer
	if buffer == nil {
		return
	}

	// Create GPU data if not initialized
	if !text_data.gpu_data.initialized {
		gl.GenVertexArrays(1, &text_data.gpu_data.vao)
		gl.GenBuffers(1, &text_data.gpu_data.vbo)
		gl.GenBuffers(1, &text_data.gpu_data.ebo)
		text_data.gpu_data.initialized = true
	}

	// Ensure the glyph cache is updated
	update_glyph_cache_buffers(cache)

	// Create vertex and index buffers
	vertices := make([dynamic]Buffer_Vertex)
	indices := make([dynamic]i32)
	defer delete(vertices)
	defer delete(indices)

	x, y := position[0], position[1]
	em_scale := f32(text_data.font_size) / f32(font.units_per_em)

	for i := 0; i < len(buffer.glyphs); i += 1 {
		gi := buffer.glyphs[i]
		pos := buffer.positions[i]

		// Get or cache this glyph
		font_id := u32(text_data.font_id)
		size := text_data.font_size
		glyph_entry, ok := get_or_cache_glyph(cache, font, gi.glyph_id, font_id, size)
		if !ok {
			// Skip if we couldn't process this glyph
			continue
		}

		// Skip empty glyphs (spaces, etc.)
		if glyph_entry.metrics.bbox.max[0] - glyph_entry.metrics.bbox.min[0] <= 0 ||
		   glyph_entry.metrics.bbox.max[1] - glyph_entry.metrics.bbox.min[1] <= 0 {
			x += f32(pos.x_advance) * em_scale
			continue
		}

		// Calculate glyph dimensions based on bounding box
		bbox_width := f32(glyph_entry.metrics.bbox.max[0] - glyph_entry.metrics.bbox.min[0])
		bbox_height := f32(glyph_entry.metrics.bbox.max[1] - glyph_entry.metrics.bbox.min[1])

		// Calculate left and top bearings
		lsb := f32(glyph_entry.metrics.lsb)
		tsb := f32(glyph_entry.metrics.tsb)

		// Apply positioning
		glyph_x := x + lsb * em_scale + f32(pos.x_offset) * em_scale
		glyph_y := y - tsb * em_scale + f32(pos.y_offset) * em_scale

		// Texture coordinates for UV mapping
		// Normalize to font units
		u0 := f32(glyph_entry.metrics.bbox.min[0])
		v0 := f32(glyph_entry.metrics.bbox.min[1])
		u1 := f32(glyph_entry.metrics.bbox.max[0])
		v1 := f32(glyph_entry.metrics.bbox.max[1])

		// Add vertices for this glyph
		width := bbox_width * em_scale
		height := bbox_height * em_scale

		base_index := len(vertices)
		append(&vertices, Buffer_Vertex{glyph_x, glyph_y, u0, v0, glyph_entry.buffer_index})
		append(
			&vertices,
			Buffer_Vertex{glyph_x + width, glyph_y, u1, v0, glyph_entry.buffer_index},
		)
		append(
			&vertices,
			Buffer_Vertex{glyph_x + width, glyph_y + height, u1, v1, glyph_entry.buffer_index},
		)
		append(
			&vertices,
			Buffer_Vertex{glyph_x, glyph_y + height, u0, v1, glyph_entry.buffer_index},
		)

		// Add indices (two triangles per quad)
		append(&indices, i32(base_index), i32(base_index + 1), i32(base_index + 2))
		append(&indices, i32(base_index + 2), i32(base_index + 3), i32(base_index))

		// Advance x position
		x += f32(pos.x_advance) * em_scale
	}

	// Upload vertex and index data to GPU
	gl.BindVertexArray(text_data.gpu_data.vao)

	gl.BindBuffer(gl.ARRAY_BUFFER, text_data.gpu_data.vbo)
	gl.BufferData(
		gl.ARRAY_BUFFER,
		size_of(Buffer_Vertex) * len(vertices),
		raw_data(vertices),
		gl.DYNAMIC_DRAW,
	)

	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, text_data.gpu_data.ebo)
	gl.BufferData(
		gl.ELEMENT_ARRAY_BUFFER,
		size_of(i32) * len(indices),
		raw_data(indices),
		gl.DYNAMIC_DRAW,
	)

	// Set up vertex attributes
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(
		0,
		2,
		gl.FLOAT,
		false,
		size_of(Buffer_Vertex),
		cast(uintptr)offset_of(Buffer_Vertex, x),
	)
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(
		1,
		2,
		gl.FLOAT,
		false,
		size_of(Buffer_Vertex),
		cast(uintptr)offset_of(Buffer_Vertex, u),
	)
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribIPointer(
		2,
		1,
		gl.INT,
		size_of(Buffer_Vertex),
		cast(uintptr)offset_of(Buffer_Vertex, buffer_index),
	)

	gl.BindVertexArray(0)

	text_data.gpu_data.vertex_count = i32(len(vertices))
	text_data.gpu_data.index_count = i32(len(indices))
}

// Render a text element using the shader
render_text :: proc(text_data: ^Text_Data, shader_program: u32, cache: ^Glyph_Cache) {
	if !text_data.gpu_data.initialized || text_data.gpu_data.index_count == 0 {
		return
	}

	// Bind shader program
	gl.UseProgram(shader_program)

	// Set uniforms
	color_loc := gl.GetUniformLocation(shader_program, "color")
	glyphs_loc := gl.GetUniformLocation(shader_program, "glyphs")
	curves_loc := gl.GetUniformLocation(shader_program, "curves")

	// Matrix uniforms should already be set before this call

	// Set color from text data
	color := text_data.text_color
	gl.Uniform4f(color_loc, color.r, color.g, color.b, color.a)

	// Set texture samplers
	gl.Uniform1i(glyphs_loc, 0)
	gl.Uniform1i(curves_loc, 1)

	// Bind textures
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_BUFFER, cache.glyph_texture_id)

	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_BUFFER, cache.curve_texture_id)

	// Enable blending (for proper alpha transparency)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

	// Bind VAO and draw
	gl.BindVertexArray(text_data.gpu_data.vao)
	gl.DrawElements(gl.TRIANGLES, text_data.gpu_data.index_count, gl.UNSIGNED_INT, nil)

	// Clean up
	gl.BindVertexArray(0)
	gl.Disable(gl.BLEND)
	gl.UseProgram(0)
}
