// Vulkan device for the GPU GS: instance, device and queue, buffers with
// device addresses, pipelines, and an optional swapchain. Headless runs
// have no surface and render the same way.
package gs

import "core:dynlib"
import "core:fmt"
import "core:os"
import vk "vendor:vulkan"

@(private)
Buf :: struct {
	buf:  vk.Buffer,
	mem:  vk.DeviceMemory,
	addr: vk.DeviceAddress,
	ptr:  [^]u8, // mapped, for host-visible buffers
	size: int,
}

@(private)
vkc: struct {
	instance:  vk.Instance,
	phys:      vk.PhysicalDevice,
	device:    vk.Device,
	queue:     vk.Queue,
	family:    u32,
	mem_props: vk.PhysicalDeviceMemoryProperties,
	pool:      vk.CommandPool,
	surface:   vk.SurfaceKHR,
	swap:      vk.SwapchainKHR,
	swap_fmt:  vk.Format,
	swap_ext:  vk.Extent2D,
	swap_imgs: [dynamic]vk.Image,
	swap_done: [dynamic]vk.Semaphore, // per image: rendering finished, safe to present
}

@(private)
vk_check :: proc(r: vk.Result, what: string, loc := #caller_location) {
	if r != .SUCCESS {
		fmt.eprintfln("vulkan: %s failed: %v (%v)", what, r, loc)
		os.exit(1)
	}
}

// Load the loader and create the instance with the surface extensions the
// window system needs.
@(private)
vk_instance :: proc(extensions: []cstring) {
	lib, ok := dynlib.load_library("libvulkan.so.1")
	if !ok {
		fmt.eprintln("vulkan: libvulkan.so.1 not found")
		os.exit(1)
	}
	gipa, found := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	assert(found, "vkGetInstanceProcAddr")
	vk.load_proc_addresses_global(gipa)
	app := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "Nicktoons Unite!",
		apiVersion       = vk.API_VERSION_1_3,
	}
	info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app,
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}
	vk_check(vk.CreateInstance(&info, nil, &vkc.instance), "vkCreateInstance")
	vk.load_proc_addresses_instance(vkc.instance)
}

// Pick the first device with a graphics queue and pixel interlock, and
// create it with the features the shaders use.
@(private)
vk_device :: proc() {
	n: u32
	vk.EnumeratePhysicalDevices(vkc.instance, &n, nil)
	devs := make([]vk.PhysicalDevice, n, context.temp_allocator)
	vk.EnumeratePhysicalDevices(vkc.instance, &n, raw_data(devs))
	for d in devs {
		lock := vk.PhysicalDeviceFragmentShaderInterlockFeaturesEXT {
			sType = .PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT,
		}
		f2 := vk.PhysicalDeviceFeatures2 {
			sType = .PHYSICAL_DEVICE_FEATURES_2,
			pNext = &lock,
		}
		vk.GetPhysicalDeviceFeatures2(d, &f2)
		if !lock.fragmentShaderPixelInterlock {continue}
		qn: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(d, &qn, nil)
		qs := make([]vk.QueueFamilyProperties, qn, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(d, &qn, raw_data(qs))
		for q, i in qs {
			if .GRAPHICS not_in q.queueFlags || .COMPUTE not_in q.queueFlags {continue}
			if vkc.surface != 0 {
				present: b32
				vk.GetPhysicalDeviceSurfaceSupportKHR(d, u32(i), vkc.surface, &present)
				if !present {continue}
			}
			vkc.phys, vkc.family = d, u32(i)
			break
		}
		if vkc.phys != nil {break}
	}
	if vkc.phys == nil {
		fmt.eprintln("vulkan: no device with fragment shader pixel interlock")
		os.exit(1)
	}
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(vkc.phys, &props)
	fmt.eprintfln("vulkan: %s", cstring(&props.deviceName[0]))
	vk.GetPhysicalDeviceMemoryProperties(vkc.phys, &vkc.mem_props)

	lock := vk.PhysicalDeviceFragmentShaderInterlockFeaturesEXT {
		sType                        = .PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT,
		fragmentShaderPixelInterlock = true,
	}
	v13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext            = &lock,
		dynamicRendering = true,
	}
	v12 := vk.PhysicalDeviceVulkan12Features {
		sType               = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext               = &v13,
		bufferDeviceAddress = true,
	}
	f2 := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &v12,
		features = {fragmentStoresAndAtomics = true},
	}
	prio: f32 = 1
	qinfo := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = vkc.family,
		queueCount       = 1,
		pQueuePriorities = &prio,
	}
	exts := [2]cstring{"VK_EXT_fragment_shader_interlock", "VK_KHR_swapchain"}
	info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &f2,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &qinfo,
		enabledExtensionCount   = vkc.surface != 0 ? 2 : 1,
		ppEnabledExtensionNames = &exts[0],
	}
	vk_check(vk.CreateDevice(vkc.phys, &info, nil, &vkc.device), "vkCreateDevice")
	vk.load_proc_addresses_device(vkc.device)
	vk.GetDeviceQueue(vkc.device, vkc.family, 0, &vkc.queue)
	pool := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = vkc.family,
	}
	vk_check(vk.CreateCommandPool(vkc.device, &pool, nil, &vkc.pool), "vkCreateCommandPool")
}

@(private)
mem_type :: proc(bits: u32, want: vk.MemoryPropertyFlags) -> u32 {
	for i in 0 ..< vkc.mem_props.memoryTypeCount {
		if bits & (1 << i) != 0 && want <= vkc.mem_props.memoryTypes[i].propertyFlags {return i}
	}
	fmt.eprintln("vulkan: no memory type with", want)
	os.exit(1)
}

// A buffer with a device address; host-visible ones stay mapped.
@(private)
buf_create :: proc(size: int, usage: vk.BufferUsageFlags, want: vk.MemoryPropertyFlags) -> (b: Buf) {
	b.size = size
	info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(size),
		usage = usage + {.SHADER_DEVICE_ADDRESS},
	}
	vk_check(vk.CreateBuffer(vkc.device, &info, nil, &b.buf), "vkCreateBuffer")
	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(vkc.device, b.buf, &req)
	flags := vk.MemoryAllocateFlagsInfo {
		sType = .MEMORY_ALLOCATE_FLAGS_INFO,
		flags = {.DEVICE_ADDRESS},
	}
	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		pNext           = &flags,
		allocationSize  = req.size,
		memoryTypeIndex = mem_type(req.memoryTypeBits, want),
	}
	vk_check(vk.AllocateMemory(vkc.device, &alloc, nil, &b.mem), "vkAllocateMemory")
	vk_check(vk.BindBufferMemory(vkc.device, b.buf, b.mem, 0), "vkBindBufferMemory")
	addr := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = b.buf,
	}
	b.addr = vk.GetBufferDeviceAddress(vkc.device, &addr)
	if .HOST_VISIBLE in want {
		p: rawptr
		vk_check(vk.MapMemory(vkc.device, b.mem, 0, vk.DeviceSize(size), {}, &p), "vkMapMemory")
		b.ptr = ([^]u8)(p)
	}
	return
}

@(private)
image_create :: proc(w, h: u32, format: vk.Format, usage: vk.ImageUsageFlags) -> (img: vk.Image, mem: vk.DeviceMemory) {
	info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format,
		extent        = {w, h, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = usage,
		initialLayout = .UNDEFINED,
	}
	vk_check(vk.CreateImage(vkc.device, &info, nil, &img), "vkCreateImage")
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(vkc.device, img, &req)
	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = mem_type(req.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk_check(vk.AllocateMemory(vkc.device, &alloc, nil, &mem), "vkAllocateMemory")
	vk_check(vk.BindImageMemory(vkc.device, img, mem, 0), "vkBindImageMemory")
	return
}

@(private)
shader_module :: proc(code: []u8) -> (m: vk.ShaderModule) {
	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = ([^]u32)(raw_data(code)),
	}
	vk_check(vk.CreateShaderModule(vkc.device, &info, nil, &m), "vkCreateShaderModule")
	return
}

@(private)
layout_create :: proc(stages: vk.ShaderStageFlags, push: u32) -> (l: vk.PipelineLayout) {
	rng := vk.PushConstantRange {
		stageFlags = stages,
		size       = push,
	}
	info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &rng,
	}
	vk_check(vk.CreatePipelineLayout(vkc.device, &info, nil, &l), "vkCreatePipelineLayout")
	return
}

@(private)
compute_pipeline :: proc(code: []u8, layout: vk.PipelineLayout) -> (p: vk.Pipeline) {
	m := shader_module(code)
	defer vk.DestroyShaderModule(vkc.device, m, nil)
	info := vk.ComputePipelineCreateInfo {
		sType = .COMPUTE_PIPELINE_CREATE_INFO,
		stage = {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.COMPUTE}, module = m, pName = "main"},
		layout = layout,
	}
	vk_check(vk.CreateComputePipelines(vkc.device, 0, 1, &info, nil, &p), "vkCreateComputePipelines")
	return
}

// Triangle lists with no attachments: the fragment shader does all memory
// access itself.
@(private)
prim_pipeline :: proc(vert, frag: []u8, layout: vk.PipelineLayout) -> (p: vk.Pipeline) {
	vm, fm := shader_module(vert), shader_module(frag)
	defer {
		vk.DestroyShaderModule(vkc.device, vm, nil)
		vk.DestroyShaderModule(vkc.device, fm, nil)
	}
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vm, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fm, pName = "main"},
	}
	vin := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	ia := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	vp := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	rs := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {},
		frontFace   = .COUNTER_CLOCKWISE,
		lineWidth   = 1,
	}
	ms := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	cb := vk.PipelineColorBlendStateCreateInfo {
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
	}
	dyn_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dyn := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = 2,
		pDynamicStates    = &dyn_states[0],
	}
	rend := vk.PipelineRenderingCreateInfo {
		sType = .PIPELINE_RENDERING_CREATE_INFO,
	}
	info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rend,
		stageCount          = 2,
		pStages             = &stages[0],
		pVertexInputState   = &vin,
		pInputAssemblyState = &ia,
		pViewportState      = &vp,
		pRasterizationState = &rs,
		pMultisampleState   = &ms,
		pColorBlendState    = &cb,
		pDynamicState       = &dyn,
		layout              = layout,
	}
	vk_check(vk.CreateGraphicsPipelines(vkc.device, 0, 1, &info, nil, &p), "vkCreateGraphicsPipelines")
	return
}

// (Re)create the swapchain at the surface's current size. Images are blit
// targets only.
@(private)
swap_create :: proc() {
	vk.DeviceWaitIdle(vkc.device)
	caps: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vkc.phys, vkc.surface, &caps)
	ext := caps.currentExtent
	if ext.width == 0xffffffff {ext = {640, 480}}
	if ext.width == 0 || ext.height == 0 {return} // minimised
	if vkc.swap_fmt == .UNDEFINED {
		n: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(vkc.phys, vkc.surface, &n, nil)
		fmts := make([]vk.SurfaceFormatKHR, n, context.temp_allocator)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(vkc.phys, vkc.surface, &n, raw_data(fmts))
		vkc.swap_fmt = fmts[0].format
		for f in fmts {
			if f.format == .B8G8R8A8_UNORM || f.format == .R8G8B8A8_UNORM {vkc.swap_fmt = f.format; break}
		}
	}
	mode := vk.PresentModeKHR.FIFO
	{
		n: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(vkc.phys, vkc.surface, &n, nil)
		modes := make([]vk.PresentModeKHR, n, context.temp_allocator)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(vkc.phys, vkc.surface, &n, raw_data(modes))
		// The game paces itself; presentation must not block it.
		for m in modes {if m == .MAILBOX {mode = .MAILBOX}}
		if mode != .MAILBOX {for m in modes {if m == .IMMEDIATE {mode = .IMMEDIATE}}}
	}
	count := max(caps.minImageCount + 1, 3)
	if caps.maxImageCount != 0 {count = min(count, caps.maxImageCount)}
	old := vkc.swap
	info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = vkc.surface,
		minImageCount    = count,
		imageFormat      = vkc.swap_fmt,
		imageColorSpace  = .SRGB_NONLINEAR,
		imageExtent      = ext,
		imageArrayLayers = 1,
		imageUsage       = {.TRANSFER_DST},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = mode,
		clipped          = true,
		oldSwapchain     = old,
	}
	vk_check(vk.CreateSwapchainKHR(vkc.device, &info, nil, &vkc.swap), "vkCreateSwapchainKHR")
	if old != 0 {vk.DestroySwapchainKHR(vkc.device, old, nil)}
	vkc.swap_ext = ext
	n: u32
	vk.GetSwapchainImagesKHR(vkc.device, vkc.swap, &n, nil)
	resize(&vkc.swap_imgs, int(n))
	vk.GetSwapchainImagesKHR(vkc.device, vkc.swap, &n, raw_data(vkc.swap_imgs))
	for len(vkc.swap_done) < int(n) {
		s: vk.Semaphore
		sinfo := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		vk_check(vk.CreateSemaphore(vkc.device, &sinfo, nil, &s), "vkCreateSemaphore")
		append(&vkc.swap_done, s)
	}
}
