package olay

import "core:fmt"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

import hinter "../runic/hinter"
import shaper "../runic/shaper"
import ttf "../runic/ttf"
import la "core:math/linalg"

load_font :: proc() -> (font_id: shaper.Font_ID, engine: ^shaper.Engine) {
	font_path := "./arial.ttf"
	font, err := ttf.load_font(font_path, context.allocator)
	if err != .None {
		fmt.eprintln("Error loading font:", err)
		return
	}

	engine = shaper.create_engine()
	ok: bool
	font_id, ok = shaper.register_font(engine, font)
	if !ok {
		fmt.eprintln("Error registering font")
		return
	}
	return font_id, engine
}

shape_text :: proc(
	engine: ^shaper.Engine,
	font_id: shaper.Font_ID,
	text: string,
) -> (
	buf: ^shaper.Shaping_Buffer,
	ok: bool,
) {
	features := shaper.create_feature_set(
		.ccmp, // Glyph composition/decomposition
		.liga, // Standard ligatures
		.clig, // Contextual ligatures
		.dlig, // discretionary ligatures
		.kern, // Kerning
		.mark, // Mark positioning
	)

	size_px := f32(72)

	buf, ok = shaper.shape_text_with_font(engine, font_id, text, .latn, .dflt, features)
	return
}


main :: proc() {
	fmt.println("Starting OLAY Simple Test")
	font_id, engine := load_font()
	defer shaper.destroy_engine(engine)

	// Load the actual font for GPU rendering
	font_path := "./arial.ttf"
	font, err := ttf.load_font(font_path, context.allocator)
	if err != .None {
		fmt.eprintln("Error loading font:", err)
		return
	}

	// Shape "Hello" text
	hello_text := "Hello"
	hello_buffer, hello_ok := shape_text(engine, font_id, hello_text)
	assert(hello_ok)
	defer shaper.release_buffer(engine, hello_buffer)

	ok := sdl.Init({.VIDEO})
	if !ok {
		fmt.println("Failed to init SDL:", sdl.GetError())
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow(
		"OLAY Simple Test",
		1000,
		800,
		{.RESIZABLE, .HIGH_PIXEL_DENSITY, .OPENGL},
	)
	if window == nil {
		fmt.println("Failed to create window:", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	// Create OpenGL context
	gl_context := sdl.GL_CreateContext(window)
	if gl_context == nil {
		fmt.println("Failed to create OpenGL context:", sdl.GetError())
		return
	}
	// defer sdl.GL_DeleteContext(gl_context)

	// Load OpenGL functions
	gl_proc_loader :: proc(p: rawptr, name: cstring) {
		ptr := sdl.GL_GetProcAddress(name)
		(^sdl.FunctionPointer)(p)^ = ptr
	}
	gl.load_up_to(3, 3, gl_proc_loader)

	// Set vsync
	sdl.GL_SetSwapInterval(1)

	renderer := sdl.CreateRenderer(window, nil)
	if renderer == nil {
		fmt.println("Failed to create renderer:", sdl.GetError())
		return
	}
	defer sdl.DestroyRenderer(renderer)

	// Initialize glyph cache
	glyph_cache: Glyph_Cache
	init_glyph_cache(&glyph_cache)
	defer destroy_glyph_cache(&glyph_cache)

	// Load and compile shaders
	font_shader, shader_ok := compile_shader_program(font_vtx_shader, font_frag_shader)
	if !shader_ok {
		fmt.println("Failed to create font shader program")
		return
	}
	defer gl.DeleteProgram(font_shader)

	// Create text element for "Hello"
	hello_element := create_text_element(nil, "hello_text", hello_text, font_id, engine, 32)
	hello_element.position = {50, 400} // Position in window
	hello_data := hello_element.data.(^Text_Data)
	hello_data.text_color = {1.0, 1.0, 1.0, 1.0} // White text

	// Process the text for GPU rendering (only need to do this once for static text)
	prepare_text_gpu_data(hello_data, font, &glyph_cache, {50, 400})

	BLUE := Color{0.0, 0.5, 0.7, 1.0}
	PINK := Color{1.0, 0.4, 0.4, 1.0}
	YELLOW := Color{1.0, 0.9, 0.0, 1.0}

	pink_width := 300
	i := 0

	//////// Main loop \\\\\\\\\
	running := true
	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				if event.key.scancode == .ESCAPE {
					running = false
				}
			}
		}

		sdl.SetRenderDrawColor(renderer, 50, 50, 50, 255)
		sdl.RenderClear(renderer)

		// Create scope to pop the elements
		defer i += 1
		root, pink, yellow: ^Element
		{
			root = push_element(nil, "Blue")
			root.background_color = BLUE
			root.flags = {.Flow_Horizontal, .Has_Border}
			root.constraints.x.mode = .Fixed
			root.constraints.y.mode = .Fit
			root.size = {760, 96}
			root.padding = {16, 16, 16, 16}
			root.child_gap = 24

			pink = push_element(root, "pink")
			pink.background_color = PINK
			pink.constraints.x.mode = .Fixed
			pink.constraints.y.mode = .Fixed
			pink.size = {max(f32(pink_width - i * 20), 25), 300}

			yellow = push_element(root, "yellow")
			yellow.background_color = YELLOW
			yellow.constraints.x.mode = .Grow
			yellow.constraints.y.mode = .Grow
		}
		defer free_element_tree(root)

		compute_layout(root)

		// Print sizes after layout calculation
		fmt.println("Sizes after layout calculation:")
		fmt.printf("Blue: %.0f x %.0f\n", root.size.x, root.size.y)
		fmt.printf("Pink: %.0f x %.0f\n", pink.size.x, pink.size.y)
		fmt.printf("Yellow: %.0f x %.0f\n", yellow.size.x, yellow.size.y)

		// Print positions after position calculation
		fmt.println("Positions after calculation:")
		fmt.printf("Blue: %.0f, %.0f\n", root.position.x, root.position.y)
		fmt.printf("Pink: %.0f, %.0f\n", pink.position.x, pink.position.y)
		fmt.printf("Yellow: %.0f, %.0f\n", yellow.position.x, yellow.position.y)

		// 4. Render the layout
		render_layout(renderer, root)

		// 5. Render text using OpenGL
		// Get window dimensions for projection matrix
		width, height: i32
		sdl.GetWindowSize(window, &width, &height)

		// Set up OpenGL viewport
		gl.Viewport(0, 0, width, height)

		// Set up orthographic projection matrix
		projection := orthographic_projection(0, f32(width), 0, f32(height))

		// Set up matrices in shader
		gl.UseProgram(font_shader)
		projection_loc := gl.GetUniformLocation(font_shader, "projection")
		model_loc := gl.GetUniformLocation(font_shader, "model")

		gl.UniformMatrix4fv(projection_loc, 1, false, &projection[0][0])
		ident := la.identity_matrix(matrix[4, 4]f32)
		gl.UniformMatrix4fv(model_loc, 1, false, &ident[0, 0])

		// Render the text
		render_text(hello_data, font_shader, &glyph_cache)

		// Reset OpenGL state
		gl.UseProgram(0)

		// Present the SDL renderer
		sdl.RenderPresent(renderer)

		// Add a slight delay
		sdl.Delay(1000)
	}

	fmt.println("OLAY test program ended")
}

// These helper functions will be needed

// Create an orthographic projection matrix
orthographic_projection :: proc(
	left, right, bottom, top: f32,
	near := -1.0,
	far := 1.0,
) -> matrix[4, 4]f32 {
	mat: matrix[4, 4]f32

	mat[0, 0] = 2.0 / (right - left)
	mat[1, 1] = 2.0 / (top - bottom)
	mat[2, 2] = -2.0 / f32(far - near)

	mat[3, 0] = -(right + left) / (right - left)
	mat[3, 1] = -(top + bottom) / (top - bottom)
	mat[3, 2] = -f32(far + near) / f32(far - near)
	mat[3, 3] = 1.0

	return mat
}

render_layout :: proc(renderer: ^sdl.Renderer, element: ^Element) {
	// Draw this element
	rect := sdl.FRect{element.position.x, element.position.y, element.size.x, element.size.y}
	color := element.background_color
	sdl.SetRenderDrawColor(
		renderer,
		u8(color.r * 255),
		u8(color.g * 255),
		u8(color.b * 255),
		u8(color.a * 255),
	)
	sdl.RenderFillRect(renderer, &rect)

	if .Has_Border in element.flags {
		draw_rect_border(renderer, &rect, {255, 0, 255, 255}, 1)
	}
	// render children:
	for child in element.children {
		render_layout(renderer, child)
	}
}

// Clean up element tree
free_element_tree :: proc(element: ^Element) {
	if element == nil {return}

	// Free children first
	if element.children != nil {
		for child in element.children {
			free_element_tree(child)
		}
		delete(element.children)
	}

	// Free the element itself
	free(element)
}


draw_rect_border :: proc(
	renderer: ^sdl.Renderer,
	rect: ^sdl.FRect,
	color: [4]u8,
	thickness: f32 = 1,
) {
	// Top border
	top_border := sdl.FRect{rect.x, rect.y, rect.w, thickness}

	// Bottom border
	bottom_border := sdl.FRect{rect.x, rect.y + rect.h - thickness, rect.w, thickness}

	// Left border
	left_border := sdl.FRect{rect.x, rect.y, thickness, rect.h}

	// Right border
	right_border := sdl.FRect{rect.x + rect.w - thickness, rect.y, thickness, rect.h}

	// Set border color
	sdl.SetRenderDrawColor(renderer, color[0], color[1], color[2], color[3])

	// Draw the four border rectangles
	sdl.RenderFillRect(renderer, &top_border)
	sdl.RenderFillRect(renderer, &bottom_border)
	sdl.RenderFillRect(renderer, &left_border)
	sdl.RenderFillRect(renderer, &right_border)
}
