// vkyuv: sample YUV AHardwareBuffers through Vulkan the way HWUI/Skia does (external format,
// VkSamplerYcbcrConversion with the driver's suggested components, foreign-queue acquire) and
// compare the result with the CPU's view of the same pixels.
//
//   vkyuv synth                        CPU-written YV12/NV12/NV21/P010 buffers at several sizes
//   vkyuv anw                          YV12 frames written through ANativeWindow_lock, as
//                                      ExoPlayer's software extensions and Instagram do
//   vkyuv codec <file> <decoder> [n]   frame n of <file> from <decoder> into a GPU-sampled
//                                      ImageReader, against the same decoder into a CPU-read one
//
// Each case is rendered twice: with the RGB_IDENTITY model (raw Y/Cb/Cr, an exact layout
// check; YCBCR_IDENTITY would still apply range expansion) and with the driver's suggested
// model/range (what HWUI uses). "bad" is the share of
// pixels where some channel is off by more than the tolerance; a layout bug shows as tens of %.
#include <android/hardware_buffer.h>
#include <fcntl.h>
#include <math.h>
#include <android/native_window.h>
#include <media/NdkImageReader.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#define VK_USE_PLATFORM_ANDROID_KHR
#include <vulkan/vulkan.h>

#include "quad_vert.h"
#include "sample_frag.h"

#define CHECK(x)                                                                   \
	do {                                                                           \
		VkResult r_ = (x);                                                         \
		if (r_ != VK_SUCCESS) {                                                    \
			fprintf(stderr, "%s:%d: %s = %d\n", __FILE__, __LINE__, #x, r_);       \
			exit(1);                                                               \
		}                                                                          \
	} while (0)

static VkInstance inst;
static VkPhysicalDevice pd;
static VkDevice dev;
static VkQueue queue;
static uint32_t qf;
static VkCommandPool cpool;
static VkShaderModule vs, fs;
static VkPhysicalDeviceMemoryProperties memprops;
static PFN_vkGetAndroidHardwareBufferPropertiesANDROID get_ahb_props;

// The CPU's view of a frame: 8-bit planes, chroma at half resolution.
struct frame {
	int w, h, cw;
	uint8_t *y, *cb, *cr;
};

static void vk_init(void) {
	VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1};
	VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
	CHECK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	vkEnumeratePhysicalDevices(inst, &n, &pd);
	VkPhysicalDeviceProperties p;
	vkGetPhysicalDeviceProperties(pd, &p);
	printf("# %s, driver %u.%u.%u\n", p.deviceName, VK_VERSION_MAJOR(p.driverVersion),
	       VK_VERSION_MINOR(p.driverVersion), VK_VERSION_PATCH(p.driverVersion));
	vkGetPhysicalDeviceMemoryProperties(pd, &memprops);

	VkQueueFamilyProperties qfp[8];
	n = 8;
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, qfp);
	for (qf = 0; qf < n && !(qfp[qf].queueFlags & VK_QUEUE_GRAPHICS_BIT); qf++);
	float prio = 1;
	VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
	                               .queueFamilyIndex = qf, .queueCount = 1, .pQueuePriorities = &prio};
	const char *exts[] = {VK_ANDROID_EXTERNAL_MEMORY_ANDROID_HARDWARE_BUFFER_EXTENSION_NAME,
	                      VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME};
	VkPhysicalDeviceSamplerYcbcrConversionFeatures ycf = {
	    .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES,
	    .samplerYcbcrConversion = VK_TRUE};
	VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &ycf,
	                          .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
	                          .enabledExtensionCount = 2, .ppEnabledExtensionNames = exts};
	CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, qf, 0, &queue);
	get_ahb_props = (PFN_vkGetAndroidHardwareBufferPropertiesANDROID)vkGetDeviceProcAddr(
	    dev, "vkGetAndroidHardwareBufferPropertiesANDROID");
	VkCommandPoolCreateInfo cpi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
	                               .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
	                               .queueFamilyIndex = qf};
	CHECK(vkCreateCommandPool(dev, &cpi, NULL, &cpool));
	VkShaderModuleCreateInfo smi = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
	                                .codeSize = sizeof(quad_vert), .pCode = quad_vert};
	CHECK(vkCreateShaderModule(dev, &smi, NULL, &vs));
	smi.codeSize = sizeof(sample_frag);
	smi.pCode = sample_frag;
	CHECK(vkCreateShaderModule(dev, &smi, NULL, &fs));
}

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags want) {
	for (uint32_t i = 0; i < memprops.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (memprops.memoryTypes[i].propertyFlags & want) == want) return i;
	fprintf(stderr, "no memory type for bits %#x flags %#x\n", bits, want);
	exit(1);
}

struct sample_info {
	uint64_t ext_format;
	VkFormat vk_format;
	VkSamplerYcbcrModelConversion model;
	VkSamplerYcbcrRange range;
};

// Render `b` (W x H, its full size) into RGBA8 with the given conversion model; NULL model = the
// driver's suggestion. Returns malloc'd RGBA pixels.
static uint8_t *vk_sample(AHardwareBuffer *b, int identity, struct sample_info *si) {
	AHardwareBuffer_Desc desc;
	AHardwareBuffer_describe(b, &desc);
	uint32_t W = desc.width, H = desc.height;

	VkAndroidHardwareBufferFormatPropertiesANDROID fp = {
	    .sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID};
	VkAndroidHardwareBufferPropertiesANDROID ap = {
	    .sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID, .pNext = &fp};
	CHECK(get_ahb_props(dev, b, &ap));
	si->ext_format = fp.format == VK_FORMAT_UNDEFINED ? fp.externalFormat : 0;
	si->vk_format = fp.format;
	si->model = identity ? VK_SAMPLER_YCBCR_MODEL_CONVERSION_RGB_IDENTITY : fp.suggestedYcbcrModel;
	si->range = identity ? VK_SAMPLER_YCBCR_RANGE_ITU_FULL : fp.suggestedYcbcrRange;

	VkExternalFormatANDROID ef_img = {.sType = VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_ANDROID,
	                                  .externalFormat = si->ext_format};
	VkExternalFormatANDROID ef_conv = ef_img;
	VkExternalMemoryImageCreateInfo emi = {.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
	                                       .pNext = &ef_img,
	                                       .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID};
	VkImageCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &emi,
	                         .imageType = VK_IMAGE_TYPE_2D, .format = fp.format, .extent = {W, H, 1},
	                         .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
	                         .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_SAMPLED_BIT,
	                         .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
	VkImage img;
	CHECK(vkCreateImage(dev, &ici, NULL, &img));
	VkImportAndroidHardwareBufferInfoANDROID imp = {
	    .sType = VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID, .buffer = b};
	VkMemoryDedicatedAllocateInfo ded = {.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
	                                     .pNext = &imp, .image = img};
	VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &ded,
	                            .allocationSize = ap.allocationSize,
	                            .memoryTypeIndex = mem_type(ap.memoryTypeBits, 0)};
	VkDeviceMemory imgmem;
	CHECK(vkAllocateMemory(dev, &mai, NULL, &imgmem));
	CHECK(vkBindImageMemory(dev, img, imgmem, 0));

	VkSamplerYcbcrConversionCreateInfo yci = {
	    .sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_CREATE_INFO, .pNext = &ef_conv,
	    .format = fp.format, .ycbcrModel = si->model, .ycbcrRange = si->range,
	    .components = fp.samplerYcbcrConversionComponents,
	    .xChromaOffset = fp.suggestedXChromaOffset, .yChromaOffset = fp.suggestedYChromaOffset,
	    .chromaFilter = VK_FILTER_NEAREST};
	VkSamplerYcbcrConversion conv;
	CHECK(vkCreateSamplerYcbcrConversion(dev, &yci, NULL, &conv));
	VkSamplerYcbcrConversionInfo sci = {.sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO,
	                                    .conversion = conv};
	VkSamplerCreateInfo smp = {.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .pNext = &sci,
	                           .magFilter = VK_FILTER_NEAREST, .minFilter = VK_FILTER_NEAREST,
	                           .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
	                           .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
	                           .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
	                           .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE};
	VkSampler sampler;
	CHECK(vkCreateSampler(dev, &smp, NULL, &sampler));
	VkImageViewCreateInfo vci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .pNext = &sci,
	                             .image = img, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = fp.format,
	                             .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
	VkImageView view;
	CHECK(vkCreateImageView(dev, &vci, NULL, &view));

	// Render target and readback buffer.
	VkImageCreateInfo tci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
	                         .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {W, H, 1}, .mipLevels = 1,
	                         .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
	                         .tiling = VK_IMAGE_TILING_OPTIMAL,
	                         .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT};
	VkImage tgt;
	CHECK(vkCreateImage(dev, &tci, NULL, &tgt));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, tgt, &mr);
	VkMemoryAllocateInfo tmai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
	                             .memoryTypeIndex = mem_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
	VkDeviceMemory tgtmem;
	CHECK(vkAllocateMemory(dev, &tmai, NULL, &tgtmem));
	CHECK(vkBindImageMemory(dev, tgt, tgtmem, 0));
	VkImageViewCreateInfo tvci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = tgt,
	                              .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
	                              .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
	VkImageView tview;
	CHECK(vkCreateImageView(dev, &tvci, NULL, &tview));
	VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = (VkDeviceSize)W * H * 4,
	                          .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
	VkBuffer rb;
	CHECK(vkCreateBuffer(dev, &bci, NULL, &rb));
	vkGetBufferMemoryRequirements(dev, rb, &mr);
	VkMemoryAllocateInfo bmai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
	                             .memoryTypeIndex = mem_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
	                                                                                VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)};
	VkDeviceMemory rbmem;
	CHECK(vkAllocateMemory(dev, &bmai, NULL, &rbmem));
	CHECK(vkBindBufferMemory(dev, rb, rbmem, 0));

	// Pipeline: the YUV image is an immutable combined sampler, as Skia sets it up.
	VkDescriptorSetLayoutBinding bind = {.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
	                                     .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
	                                     .pImmutableSamplers = &sampler};
	VkDescriptorSetLayoutCreateInfo dli = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
	                                       .bindingCount = 1, .pBindings = &bind};
	VkDescriptorSetLayout dsl;
	CHECK(vkCreateDescriptorSetLayout(dev, &dli, NULL, &dsl));
	VkPushConstantRange pcr = {VK_SHADER_STAGE_FRAGMENT_BIT, 0, 8};
	VkPipelineLayoutCreateInfo pli = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1,
	                                  .pSetLayouts = &dsl, .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr};
	VkPipelineLayout pl;
	CHECK(vkCreatePipelineLayout(dev, &pli, NULL, &pl));
	VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 4};
	VkDescriptorPoolCreateInfo dpi = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1,
	                                  .poolSizeCount = 1, .pPoolSizes = &ps};
	VkDescriptorPool dp;
	CHECK(vkCreateDescriptorPool(dev, &dpi, NULL, &dp));
	VkDescriptorSetAllocateInfo dai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp,
	                                   .descriptorSetCount = 1, .pSetLayouts = &dsl};
	VkDescriptorSet ds;
	CHECK(vkAllocateDescriptorSets(dev, &dai, &ds));
	VkDescriptorImageInfo dii = {.imageView = view, .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
	VkWriteDescriptorSet wds = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .descriptorCount = 1,
	                            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &dii};
	vkUpdateDescriptorSets(dev, 1, &wds, 0, NULL);

	VkAttachmentDescription att = {.format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT,
	                               .loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
	                               .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
	                               .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
	                               .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
	                               .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL};
	VkAttachmentReference aref = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
	VkSubpassDescription sub = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1,
	                            .pColorAttachments = &aref};
	VkRenderPassCreateInfo rpi = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1,
	                              .pAttachments = &att, .subpassCount = 1, .pSubpasses = &sub};
	VkRenderPass rp;
	CHECK(vkCreateRenderPass(dev, &rpi, NULL, &rp));
	VkFramebufferCreateInfo fbi = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rp,
	                               .attachmentCount = 1, .pAttachments = &tview, .width = W, .height = H, .layers = 1};
	VkFramebuffer fb;
	CHECK(vkCreateFramebuffer(dev, &fbi, NULL, &fb));

	VkPipelineShaderStageCreateInfo st[2] = {
	    {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
	     .module = vs, .pName = "main"},
	    {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
	     .module = fs, .pName = "main"}};
	VkPipelineVertexInputStateCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
	VkPipelineInputAssemblyStateCreateInfo ia = {.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
	                                             .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
	VkViewport vp = {0, 0, (float)W, (float)H, 0, 1};
	VkRect2D sc = {{0, 0}, {W, H}};
	VkPipelineViewportStateCreateInfo vps = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
	                                         .viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc};
	VkPipelineRasterizationStateCreateInfo rs = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
	                                             .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
	                                             .lineWidth = 1};
	VkPipelineMultisampleStateCreateInfo ms = {.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
	                                           .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
	VkPipelineColorBlendAttachmentState cba = {.colorWriteMask = 0xf};
	VkPipelineColorBlendStateCreateInfo cb = {.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
	                                          .attachmentCount = 1, .pAttachments = &cba};
	VkGraphicsPipelineCreateInfo gpi = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2,
	                                    .pStages = st, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
	                                    .pViewportState = &vps, .pRasterizationState = &rs, .pMultisampleState = &ms,
	                                    .pColorBlendState = &cb, .layout = pl, .renderPass = rp};
	VkPipeline pipe;
	CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpi, NULL, &pipe));

	VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cpool,
	                                    .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
	VkCommandBuffer cmd;
	CHECK(vkAllocateCommandBuffers(dev, &cbai, &cmd));
	VkCommandBufferBeginInfo cbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
	                                .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
	CHECK(vkBeginCommandBuffer(cmd, &cbi));
	// Acquire the producer's buffer from the foreign queue, keeping its contents.
	VkImageMemoryBarrier acq = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
	                            .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
	                            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
	                            .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
	                            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT, .dstQueueFamilyIndex = qf,
	                            .image = img, .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0,
	                     NULL, 1, &acq);
	VkRenderPassBeginInfo rbi = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rp,
	                             .framebuffer = fb, .renderArea = sc};
	vkCmdBeginRenderPass(cmd, &rbi, VK_SUBPASS_CONTENTS_INLINE);
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
	vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pl, 0, 1, &ds, 0, NULL);
	float size[2] = {(float)W, (float)H};
	vkCmdPushConstants(cmd, pl, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 8, size);
	vkCmdDraw(cmd, 3, 1, 0, 0);
	vkCmdEndRenderPass(cmd);
	VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {W, H, 1}};
	vkCmdCopyImageToBuffer(cmd, tgt, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb, 1, &copy);
	CHECK(vkEndCommandBuffer(cmd));
	VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence;
	CHECK(vkCreateFence(dev, &fci, NULL, &fence));
	VkSubmitInfo si_ = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd};
	CHECK(vkQueueSubmit(queue, 1, &si_, fence));
	CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 5000000000ull));

	uint8_t *out = malloc((size_t)W * H * 4);
	void *map;
	CHECK(vkMapMemory(dev, rbmem, 0, VK_WHOLE_SIZE, 0, &map));
	memcpy(out, map, (size_t)W * H * 4);
	vkUnmapMemory(dev, rbmem);

	vkDestroyFence(dev, fence, NULL);
	vkFreeCommandBuffers(dev, cpool, 1, &cmd);
	vkDestroyPipeline(dev, pipe, NULL);
	vkDestroyFramebuffer(dev, fb, NULL);
	vkDestroyRenderPass(dev, rp, NULL);
	vkDestroyDescriptorPool(dev, dp, NULL);
	vkDestroyPipelineLayout(dev, pl, NULL);
	vkDestroyDescriptorSetLayout(dev, dsl, NULL);
	vkDestroyBuffer(dev, rb, NULL);
	vkFreeMemory(dev, rbmem, NULL);
	vkDestroyImageView(dev, tview, NULL);
	vkDestroyImage(dev, tgt, NULL);
	vkFreeMemory(dev, tgtmem, NULL);
	vkDestroyImageView(dev, view, NULL);
	vkDestroySampler(dev, sampler, NULL);
	vkDestroySamplerYcbcrConversion(dev, conv, NULL);
	vkDestroyImage(dev, img, NULL);
	vkFreeMemory(dev, imgmem, NULL);
	return out;
}

// What the conversion should produce for one pixel, in 8-bit RGB.
static void expect(const struct sample_info *si, int y, int cb, int cr, int o[3]) {
	if (si->model == VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_IDENTITY ||
	    si->model == VK_SAMPLER_YCBCR_MODEL_CONVERSION_RGB_IDENTITY) {
		o[0] = cr, o[1] = y, o[2] = cb;
		return;
	}
	double Y, Cb, Cr, kr, kb;
	if (si->range == VK_SAMPLER_YCBCR_RANGE_ITU_NARROW)
		Y = (y - 16) / 219.0, Cb = (cb - 128) / 224.0, Cr = (cr - 128) / 224.0;
	else
		Y = y / 255.0, Cb = (cb - 128) / 255.0, Cr = (cr - 128) / 255.0;
	switch (si->model) {
	case VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_709: kr = 0.2126, kb = 0.0722; break;
	case VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_2020: kr = 0.2627, kb = 0.0593; break;
	default: kr = 0.299, kb = 0.114; break;
	}
	double R = Y + 2 * (1 - kr) * Cr, B = Y + 2 * (1 - kb) * Cb;
	double G = (Y - kr * R - kb * B) / (1 - kr - kb);
	double c[3] = {R, G, B};
	for (int i = 0; i < 3; i++) o[i] = (int)lround(fmin(fmax(c[i], 0), 1) * 255);
}

struct score {
	double bad_y, bad_c, mad;
};

// Compare the rendering (stride W) with the CPU frame over the frame's size. Luma errors are
// counted on G in identity mode (on any channel otherwise); chroma errors on R/B.
static struct score compare(const uint8_t *rgba, int W, const struct frame *f, const struct sample_info *si) {
	int raw = si->model == VK_SAMPLER_YCBCR_MODEL_CONVERSION_RGB_IDENTITY, tol = raw ? 6 : 12;
	long bad_y = 0, bad_c = 0, n = 0;
	double sum = 0;
	for (int y = 0; y < f->h; y++)
		for (int x = 0; x < f->w; x++) {
			int ci = (y / 2) * f->cw + x / 2, e[3];
			expect(si, f->y[y * f->w + x], f->cb[ci], f->cr[ci], e);
			const uint8_t *p = rgba + ((size_t)y * W + x) * 4;
			int d[3] = {abs(p[0] - e[0]), abs(p[1] - e[1]), abs(p[2] - e[2])};
			sum += d[0] + d[1] + d[2];
			if (raw) {
				bad_y += d[1] > tol;
				bad_c += d[0] > tol || d[2] > tol;
			} else {
				bad_y += d[0] > tol || d[1] > tol || d[2] > tol;
			}
			n++;
		}
	return (struct score){100.0 * bad_y / n, 100.0 * bad_c / n, sum / (3.0 * n)};
}

static const char *fmt_name(uint32_t f) {
	switch (f) {
	case 0x32315659: return "YV12";
	case 0x23: return "YCbCr_420_888";
	case 0x11: return "NV21";
	case 0x36: return "P010";
	case 0x22: return "PRIVATE";
	case 0x7fa30c04: return "NV12_UBWC";
	case 0x7fa30c06: return "NV12_VENUS";
	case 0x7fa30c09: return "TP10_UBWC";
	case 0x7fa30c0a: return "P010_VENUS";
	case 0x7fa30c0b: return "P010_UBWC";
	case 0x7fa30c03: return "NV21_VENUS";
	default: return "?";
	}
}

// Render `b` both ways and print one line for the case.
static void run_case(const char *label, AHardwareBuffer *b, const struct frame *f) {
	AHardwareBuffer_Desc d;
	AHardwareBuffer_describe(b, &d);
	struct sample_info id, sg;
	uint8_t *raw = vk_sample(b, 1, &id);
	struct score s1 = compare(raw, d.width, f, &id);
	free(raw);
	uint8_t *conv = vk_sample(b, 0, &sg);
	struct score s2 = compare(conv, d.width, f, &sg);
	free(conv);
	const char *verdict = s1.bad_y > 1 || s1.bad_c > 1 || s2.bad_y > 2 ? "FAIL" : "ok";
	printf("%-34s %-4s buf %4ux%-4u stride %4u %-10s vk %s%#llx | raw: badY %5.1f%% badC %5.1f%% mad %5.2f | "
	       "model %d range %d: bad %5.1f%% mad %5.2f\n",
	       label, verdict, d.width, d.height, d.stride, fmt_name(d.format), id.ext_format ? "ext " : "fmt ",
	       id.ext_format ? (unsigned long long)id.ext_format : (unsigned long long)id.vk_format, s1.bad_y, s1.bad_c,
	       s1.mad, sg.model, sg.range, s2.bad_y, s2.mad);
	fflush(stdout);
}

static uint8_t hash8(uint32_t x, uint32_t y, uint32_t seed) {
	uint32_t h = x * 73856093u ^ y * 19349663u ^ seed * 83492791u;
	h ^= h >> 13;
	h *= 0x5bd1e995u;
	h ^= h >> 15;
	return (uint8_t)h;
}

// Write one 8-bit sample into a plane; 16-bit planes (P010) take it in the high byte.
static void put(uint8_t *p, int wide, uint8_t v) {
	if (wide) p[0] = 0, p[1] = v;
	else p[0] = v;
}

static uint8_t get(const uint8_t *p, int wide) { return wide ? p[1] : p[0]; }

static void synth(void) {
	uint32_t fmts[] = {0x32315659, 0x23, 0x11, 0x36};
	int sizes[][2] = {{320, 240}, {360, 640}, {426, 240}, {540, 960}, {576, 1024}, {640, 360}, {720, 1280},
	                  {854, 480}, {1080, 1920}, {1088, 1920}, {1280, 720}, {1920, 1080}};
	for (unsigned fi = 0; fi < sizeof(fmts) / sizeof(*fmts); fi++)
		for (unsigned si = 0; si < sizeof(sizes) / sizeof(*sizes); si++) {
			int w = sizes[si][0], h = sizes[si][1], wide = fmts[fi] == 0x36;
			char label[64];
			snprintf(label, sizeof label, "synth %s %dx%d", fmt_name(fmts[fi]), w, h);
			AHardwareBuffer_Desc d = {.width = w, .height = h, .layers = 1, .format = fmts[fi],
			                          .usage = AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN |
			                                   AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE};
			AHardwareBuffer *b;
			if (AHardwareBuffer_allocate(&d, &b)) {
				printf("%-34s skip (allocate failed)\n", label);
				continue;
			}
			AHardwareBuffer_Planes p;
			if (AHardwareBuffer_lockPlanes(b, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, NULL, &p)) {
				printf("%-34s skip (lockPlanes failed)\n", label);
				AHardwareBuffer_release(b);
				continue;
			}
			struct frame f = {w, h, (w + 1) / 2};
			f.y = malloc(w * h), f.cb = malloc(f.cw * ((h + 1) / 2)), f.cr = malloc(f.cw * ((h + 1) / 2));
			for (int y = 0; y < h; y++)
				for (int x = 0; x < w; x++) {
					uint8_t v = hash8(x, y, 1);
					f.y[y * w + x] = v;
					put((uint8_t *)p.planes[0].data + y * p.planes[0].rowStride + x * p.planes[0].pixelStride, wide, v);
				}
			for (int y = 0; y < (h + 1) / 2; y++)
				for (int x = 0; x < f.cw; x++) {
					uint8_t u = hash8(x, y, 2), v = hash8(x, y, 3);
					f.cb[y * f.cw + x] = u, f.cr[y * f.cw + x] = v;
					put((uint8_t *)p.planes[1].data + y * p.planes[1].rowStride + x * p.planes[1].pixelStride, wide, u);
					put((uint8_t *)p.planes[2].data + y * p.planes[2].rowStride + x * p.planes[2].pixelStride, wide, v);
				}
			AHardwareBuffer_unlock(b, NULL);
			run_case(label, b, &f);
			AHardwareBuffer_release(b);
			free(f.y), free(f.cb), free(f.cr);
		}
}

// What ExoPlayer's software extensions (libvpx, libgav1, FFmpeg) and Instagram's dav1d renderer
// do: set a window to YV12 at the video size, ANativeWindow_lock it, write by the Android YV12
// contract (chroma stride ALIGN(stride/2, 16), Cr then Cb), post. The window is an ImageReader
// with the usage a TextureView's SurfaceTexture asks for.
static void anw(void) {
	int sizes[][2] = {{320, 240}, {360, 640}, {426, 240}, {540, 960}, {576, 1024}, {640, 360}, {720, 1280},
	                  {854, 480}, {1080, 1920}, {1280, 720}, {1920, 1080}};
	for (unsigned si = 0; si < sizeof(sizes) / sizeof(*sizes); si++) {
		int w = sizes[si][0], h = sizes[si][1];
		char label[64];
		snprintf(label, sizeof label, "anw YV12 %dx%d", w, h);
		AImageReader *r;
		ANativeWindow *win;
		if (AImageReader_newWithUsage(w, h, AIMAGE_FORMAT_PRIVATE, AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE, 2, &r)) {
			printf("%-34s skip (no reader)\n", label);
			continue;
		}
		AImageReader_getWindow(r, &win);
		ANativeWindow_setBuffersGeometry(win, w, h, 0x32315659);
		ANativeWindow_Buffer nb;
		if (ANativeWindow_lock(win, &nb, NULL)) {
			printf("%-34s skip (lock failed)\n", label);
			AImageReader_delete(r);
			continue;
		}
		struct frame f = {w, h, (w + 1) / 2};
		f.y = malloc(w * h), f.cb = malloc(f.cw * ((h + 1) / 2)), f.cr = malloc(f.cw * ((h + 1) / 2));
		int cs = ((nb.stride / 2) + 15) & ~15;
		uint8_t *Y = nb.bits, *Cr = Y + nb.stride * nb.height, *Cb = Cr + cs * (nb.height / 2);
		for (int y = 0; y < h; y++)
			for (int x = 0; x < w; x++) f.y[y * w + x] = Y[y * nb.stride + x] = hash8(x, y, 1);
		for (int y = 0; y < (h + 1) / 2; y++)
			for (int x = 0; x < f.cw; x++) {
				f.cb[y * f.cw + x] = Cb[y * cs + x] = hash8(x, y, 2);
				f.cr[y * f.cw + x] = Cr[y * cs + x] = hash8(x, y, 3);
			}
		ANativeWindow_unlockAndPost(win);
		AImage *img = NULL;
		for (int i = 0; i < 200 && AImageReader_acquireNextImage(r, &img) != AMEDIA_OK; i++) usleep(5000);
		if (img) {
			AHardwareBuffer *b;
			AImage_getHardwareBuffer(img, &b);
			run_case(label, b, &f);
			AImage_delete(img);
		} else printf("%-34s skip (no image)\n", label);
		AImageReader_delete(r);
		free(f.y), free(f.cb), free(f.cr);
	}
}

// Decode `path` with `name` into a new ImageReader and return its n-th image (1-based).
static AImage *decode_nth(const char *path, const char *name, int32_t fmt, uint64_t usage, int nth,
                          AImageReader **rdr, int *w, int *h) {
	int fd = open(path, O_RDONLY);
	struct stat st;
	if (fd < 0 || fstat(fd, &st)) return NULL;
	AMediaExtractor *ex = AMediaExtractor_new();
	if (AMediaExtractor_setDataSourceFd(ex, fd, 0, st.st_size) != AMEDIA_OK) return NULL;
	AMediaFormat *mf = NULL;
	for (size_t i = 0; i < AMediaExtractor_getTrackCount(ex); i++) {
		AMediaFormat *t = AMediaExtractor_getTrackFormat(ex, i);
		const char *mime;
		if (AMediaFormat_getString(t, AMEDIAFORMAT_KEY_MIME, &mime) && !strncmp(mime, "video/", 6)) {
			AMediaExtractor_selectTrack(ex, i);
			mf = t;
			break;
		}
		AMediaFormat_delete(t);
	}
	if (!mf) return NULL;
	AMediaFormat_getInt32(mf, AMEDIAFORMAT_KEY_WIDTH, w);
	AMediaFormat_getInt32(mf, AMEDIAFORMAT_KEY_HEIGHT, h);
	if (AImageReader_newWithUsage(*w, *h, fmt, usage, 3, rdr) != AMEDIA_OK) return NULL;
	ANativeWindow *win;
	AImageReader_getWindow(*rdr, &win);
	AMediaCodec *c = AMediaCodec_createCodecByName(name);
	if (!c || AMediaCodec_configure(c, mf, win, NULL, 0) != AMEDIA_OK || AMediaCodec_start(c) != AMEDIA_OK) {
		fprintf(stderr, "%s: can't start %s\n", path, name);
		return NULL;
	}
	AImage *keep = NULL;
	int count = 0, in_eos = 0;
	struct timespec t0, now;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	while (!keep) {
		clock_gettime(CLOCK_MONOTONIC, &now);
		if (now.tv_sec - t0.tv_sec > 15) break;
		if (!in_eos) {
			ssize_t i = AMediaCodec_dequeueInputBuffer(c, 2000);
			if (i >= 0) {
				size_t cap;
				uint8_t *buf = AMediaCodec_getInputBuffer(c, i, &cap);
				ssize_t n = AMediaExtractor_readSampleData(ex, buf, cap);
				if (n < 0) {
					AMediaCodec_queueInputBuffer(c, i, 0, 0, 0, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
					in_eos = 1;
				} else {
					AMediaCodec_queueInputBuffer(c, i, 0, n, AMediaExtractor_getSampleTime(ex), 0);
					AMediaExtractor_advance(ex);
				}
			}
		}
		AMediaCodecBufferInfo info;
		ssize_t o = AMediaCodec_dequeueOutputBuffer(c, &info, 2000);
		if (o >= 0) AMediaCodec_releaseOutputBuffer(c, o, info.size > 0);
		AImage *img;
		while (!keep && AImageReader_acquireNextImage(*rdr, &img) == AMEDIA_OK) {
			if (++count == nth) keep = img;
			else AImage_delete(img);
		}
	}
	AMediaCodec_stop(c);
	AMediaCodec_delete(c);
	AMediaExtractor_delete(ex);
	AMediaFormat_delete(mf);
	close(fd);
	return keep;
}

// Read the crop of a YUV buffer into `f` through gralloc's own lock (the NDK's AImage plane
// accessors return no chroma for Venus layouts). 16-bit samples (P010) keep their high byte.
static int read_frame(AHardwareBuffer *b, const AImageCropRect *cr, struct frame *f) {
	AHardwareBuffer_Planes p;
	if (AHardwareBuffer_lockPlanes(b, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN, -1, NULL, &p) || p.planeCount < 3)
		return -1;
	int wide = p.planes[0].pixelStride == 2;
	f->w = cr->right - cr->left, f->h = cr->bottom - cr->top, f->cw = (f->w + 1) / 2;
	f->y = malloc(f->w * f->h), f->cb = malloc(f->cw * ((f->h + 1) / 2)), f->cr = malloc(f->cw * ((f->h + 1) / 2));
	for (int y = 0; y < f->h; y++)
		for (int x = 0; x < f->w; x++)
			f->y[y * f->w + x] = get((uint8_t *)p.planes[0].data + (y + cr->top) * p.planes[0].rowStride +
			                             (x + cr->left) * p.planes[0].pixelStride, wide);
	for (int y = 0; y < (f->h + 1) / 2; y++)
		for (int x = 0; x < f->cw; x++) {
			int cy = y + cr->top / 2, cx = x + cr->left / 2;
			f->cb[y * f->cw + x] =
			    get((uint8_t *)p.planes[1].data + cy * p.planes[1].rowStride + cx * p.planes[1].pixelStride, wide);
			f->cr[y * f->cw + x] =
			    get((uint8_t *)p.planes[2].data + cy * p.planes[2].rowStride + cx * p.planes[2].pixelStride, wide);
		}
	AHardwareBuffer_unlock(b, NULL);
	return 0;
}

// Reference frame from ByteBuffer mode (no surface): the decoder's own CPU layout, for vendor
// formats gralloc won't lock as YUV. Handles I420 (19), NV12 (21) and P010 (54).
static int decode_bytes(const char *path, const char *name, int nth, int ten, struct frame *f) {
	int fd = open(path, O_RDONLY);
	struct stat st;
	if (fd < 0 || fstat(fd, &st)) return -1;
	AMediaExtractor *ex = AMediaExtractor_new();
	if (AMediaExtractor_setDataSourceFd(ex, fd, 0, st.st_size) != AMEDIA_OK) return -1;
	AMediaFormat *mf = NULL;
	for (size_t i = 0; i < AMediaExtractor_getTrackCount(ex) && !mf; i++) {
		AMediaFormat *t = AMediaExtractor_getTrackFormat(ex, i);
		const char *mime;
		if (AMediaFormat_getString(t, AMEDIAFORMAT_KEY_MIME, &mime) && !strncmp(mime, "video/", 6)) {
			AMediaExtractor_selectTrack(ex, i);
			mf = t;
		} else AMediaFormat_delete(t);
	}
	if (!mf) return -1;
	if (ten) AMediaFormat_setInt32(mf, AMEDIAFORMAT_KEY_COLOR_FORMAT, 54);
	AMediaCodec *c = AMediaCodec_createCodecByName(name);
	if (!c || AMediaCodec_configure(c, mf, NULL, NULL, 0) != AMEDIA_OK || AMediaCodec_start(c) != AMEDIA_OK) return -1;
	int32_t cf = 0, stride = 0, slice = 0, cl = 0, ct = 0, crr = 0, cb = 0, count = 0, in_eos = 0, done = -1;
	struct timespec t0, now;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	while (done < 0) {
		clock_gettime(CLOCK_MONOTONIC, &now);
		if (now.tv_sec - t0.tv_sec > 15) break;
		if (!in_eos) {
			ssize_t i = AMediaCodec_dequeueInputBuffer(c, 2000);
			if (i >= 0) {
				size_t cap;
				uint8_t *buf = AMediaCodec_getInputBuffer(c, i, &cap);
				ssize_t n = AMediaExtractor_readSampleData(ex, buf, cap);
				if (n < 0) AMediaCodec_queueInputBuffer(c, i, 0, 0, 0, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM), in_eos = 1;
				else AMediaCodec_queueInputBuffer(c, i, 0, n, AMediaExtractor_getSampleTime(ex), 0), AMediaExtractor_advance(ex);
			}
		}
		AMediaCodecBufferInfo info;
		ssize_t o = AMediaCodec_dequeueOutputBuffer(c, &info, 2000);
		if (o == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
			AMediaFormat *of = AMediaCodec_getOutputFormat(c);
			AMediaFormat_getInt32(of, AMEDIAFORMAT_KEY_COLOR_FORMAT, &cf);
			AMediaFormat_getInt32(of, AMEDIAFORMAT_KEY_STRIDE, &stride);
			AMediaFormat_getInt32(of, AMEDIAFORMAT_KEY_SLICE_HEIGHT, &slice);
			if (!AMediaFormat_getRect(of, AMEDIAFORMAT_KEY_DISPLAY_CROP, &cl, &ct, &crr, &cb)) {
				AMediaFormat_getInt32(of, AMEDIAFORMAT_KEY_WIDTH, &crr), crr--;
				AMediaFormat_getInt32(of, AMEDIAFORMAT_KEY_HEIGHT, &cb), cb--;
			}
			AMediaFormat_delete(of);
		}
		if (o < 0) continue;
		if (info.size > 0 && ++count == nth) {
			size_t sz;
			const uint8_t *p = AMediaCodec_getOutputBuffer(c, o, &sz) + info.offset;
			int wide = cf == 54, bps = wide ? 2 : 1;
			if (cf != 19 && cf != 21 && cf != 54) {
				fprintf(stderr, "%s: byte-buffer color format %#x not handled\n", name, cf);
				done = 1;
			} else {
				if (!slice) slice = cb + 1;
				f->w = crr - cl + 1, f->h = cb - ct + 1, f->cw = (f->w + 1) / 2;
				f->y = malloc(f->w * f->h), f->cb = malloc(f->cw * ((f->h + 1) / 2)), f->cr = malloc(f->cw * ((f->h + 1) / 2));
				const uint8_t *uv = p + (size_t)stride * slice;
				for (int y = 0; y < f->h; y++)
					for (int x = 0; x < f->w; x++) f->y[y * f->w + x] = get(p + (y + ct) * stride + (x + cl) * bps, wide);
				for (int y = 0; y < (f->h + 1) / 2; y++)
					for (int x = 0; x < f->cw; x++) {
						int cy = y + ct / 2, cx = x + cl / 2, i = y * f->cw + x;
						if (cf == 19) { // I420: U then V, half stride
							f->cb[i] = uv[cy * (stride / 2) + cx];
							f->cr[i] = uv[(size_t)(stride / 2) * (slice / 2) + cy * (stride / 2) + cx];
						} else {
							f->cb[i] = get(uv + cy * stride + cx * 2 * bps, wide);
							f->cr[i] = get(uv + cy * stride + cx * 2 * bps + bps, wide);
						}
					}
				done = 0;
			}
		}
		AMediaCodec_releaseOutputBuffer(c, o, false);
	}
	AMediaCodec_stop(c);
	AMediaCodec_delete(c);
	AMediaExtractor_delete(ex);
	AMediaFormat_delete(mf);
	close(fd);
	return done;
}

static int is_rgb(uint32_t fmt) {
	return fmt == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM || fmt == AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM ||
	       fmt == AHARDWAREBUFFER_FORMAT_R10G10B10A2_UNORM || fmt == AHARDWAREBUFFER_FORMAT_R16G16B16A16_FLOAT ||
	       fmt == AHARDWAREBUFFER_FORMAT_R5G6B5_UNORM;
}

static int codec(const char *path, const char *name, int nth) {
	char label[64];
	const char *base = strrchr(path, '/');
	snprintf(label, sizeof label, "%s %s", name, base ? base + 1 : path);
	AImageReader *rref, *rtest;
	int w, h;

	// Test: what a TextureView's SurfaceTexture asks for, GPU sampling only.
	AImage *img = decode_nth(path, name, AIMAGE_FORMAT_PRIVATE, AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE, nth, &rtest,
	                         &w, &h);
	if (!img) {
		printf("%-34s skip (no test frame)\n", label);
		return 1;
	}
	AHardwareBuffer *b;
	AImage_getHardwareBuffer(img, &b);
	AHardwareBuffer_Desc d;
	AHardwareBuffer_describe(b, &d);
	if (is_rgb(d.format)) {
		printf("%-34s n/a  decoder outputs RGB (format %#x) to a GPU consumer: no YUV sampling\n", label, d.format);
		return 0;
	}

	// Reference: the same decoder into a CPU-readable reader; 10-bit output as P010 if it can.
	int ten = d.format == AHARDWAREBUFFER_FORMAT_YCbCr_P010 || strstr(path, "10") || strstr(path, "p2");
	AImage *ref = ten ? decode_nth(path, name, 0x36 /* AIMAGE_FORMAT_YCBCR_P010 */, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN, nth,
	                               &rref, &w, &h)
	                  : NULL;
	if (!ref)
		ref = decode_nth(path, name, AIMAGE_FORMAT_YUV_420_888, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN, nth, &rref, &w,
		                 &h);
	if (!ref) {
		printf("%-34s skip (no reference frame)\n", label);
		return 1;
	}
	AImageCropRect cr, tc;
	AImage_getCropRect(ref, &cr);
	AImage_getCropRect(img, &tc);
	int64_t tref, ttest;
	AImage_getTimestamp(ref, &tref);
	AImage_getTimestamp(img, &ttest);
	if (tref != ttest) printf("# %s: frame timestamps differ (%lld vs %lld)\n", label, (long long)tref, (long long)ttest);
	if (tc.left != cr.left || tc.top != cr.top)
		printf("# %s: crop differs (%d,%d vs %d,%d)\n", label, tc.left, tc.top, cr.left, cr.top);
	AHardwareBuffer *rb;
	AImage_getHardwareBuffer(ref, &rb);
	AHardwareBuffer_Desc rd;
	AHardwareBuffer_describe(rb, &rd);
	struct frame f;
	int locked = !read_frame(rb, &cr, &f);
	AImage_delete(ref);
	AImageReader_delete(rref);
	if (!locked && decode_bytes(path, name, nth, ten, &f)) {
		printf("%-34s skip (reference buffer format %#x not lockable, no byte-buffer frame)\n", label, rd.format);
		return 1;
	}
	run_case(label, b, &f);
	AImage_delete(img);
	AImageReader_delete(rtest);
	free(f.y), free(f.cb), free(f.cr);
	return 0;
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: vkyuv synth | vkyuv anw | vkyuv codec <file> <decoder> [n]\n");
		return 2;
	}
	vk_init();
	if (!strcmp(argv[1], "synth")) synth();
	else if (!strcmp(argv[1], "anw")) anw();
	else if (!strcmp(argv[1], "codec") && argc >= 4) return codec(argv[2], argv[3], argc > 4 ? atoi(argv[4]) : 10);
	else return 2;
	return 0;
}
