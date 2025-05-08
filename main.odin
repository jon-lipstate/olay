package olay

import "core:fmt"
import sdl "vendor:sdl3"

main :: proc() {
	fmt.println("Starting OLAY Simple Test")

	ok := sdl.Init({.VIDEO})
	if !ok {
		fmt.println("Failed to init SDL:", sdl.GetError())
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("OLAY Simple Test", 1000, 800, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window == nil {
		fmt.println("Failed to create window:", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	renderer := sdl.CreateRenderer(window, nil)
	if renderer == nil {
		fmt.println("Failed to create renderer:", sdl.GetError())
		return
	}
	defer sdl.DestroyRenderer(renderer)

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
		root, pink, yellow: ^Element
		defer i += 1
		{
			root = push_element(nil, "Blue")
			root.background_color = BLUE
			root.flags = {.Flow_Horizontal, .Has_Border}
			root.sizing_type = {.Fixed, .Fit}
			root.size = {760, 96}
			root.padding = {16, 16, 16, 16}
			root.child_gap = 24

			pink = push_element(root, "pink")
			pink.background_color = PINK
			pink.sizing_type = {.Fixed, .Fixed}
			pink.size = {max(f32(pink_width - i * 20), 25), 300}

			yellow = push_element(root, "yellow")
			yellow.background_color = YELLOW
			yellow.sizing_type = {.Grow, .Grow}
			yellow.size = {0, 0}
		}
		defer free_element_tree(root)


		calculate_final_layout(root)

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

		// Present the renderer
		sdl.RenderPresent(renderer)

		// Add a slight delay
		sdl.Delay(1000)
		// break
	}

	fmt.println("OLAY test program ended")
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
