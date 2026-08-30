// fxshot - run a ReShade FX effect over a still image, headlessly, on the GPU.
//
// ReShade only runs hooked into a live application, so an effect is hard to
// test against fixed reference frames and impossible to run from CI. fxshot
// loads the HLSL and manifest that translate.py produces, builds the textures,
// mip chains and sampler states ReShade would, and runs the passes in order on
// D3D11. The pixel shaders are the effect's own, compiled by fxc.
//
// Temporal state (eye adaptation, accumulation) settles by repeating the frame
// loop, which is the equivalent of standing still.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <d3dcompiler.h>
#include <wincodec.h>
#include <DirectXPackedVector.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3dcompiler.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")

static void die(const char* msg) { fprintf(stderr, "fxshot: %s\n", msg); exit(1); }
static void dieHr(const char* msg, HRESULT hr) {
    fprintf(stderr, "fxshot: %s (hr=0x%08lx)\n", msg, (unsigned long)hr); exit(1);
}

// Minimal COM holder. Move-only on purpose: a copyable version would release the
// same interface twice once these are stored in containers.
template <class T> struct Rel {
    T* p = nullptr;
    Rel() = default;
    Rel(const Rel&) = delete;
    Rel& operator=(const Rel&) = delete;
    Rel(Rel&& o) noexcept : p(o.p) { o.p = nullptr; }
    Rel& operator=(Rel&& o) noexcept {
        // std::addressof, because operator& is overloaded to hand out T**.
        if (this != std::addressof(o)) {
            if (p) p->Release();
            p = o.p; o.p = nullptr;
        }
        return *this;
    }
    ~Rel() { if (p) p->Release(); }
    T** operator&() { return &p; }
    T* operator->() const { return p; }
    operator T*() const { return p; }
};


struct TexDef {
    std::string name, source; bool backbuffer = false;
    UINT w = 0, h = 0, mips = 1; DXGI_FORMAT fmt = DXGI_FORMAT_UNKNOWN;
};
struct SamDef { std::string name, tex; int state = 0; };
struct SamState { std::string mn, mg, mp, au, av; };
// offset is in 4-byte slots. A manifest without one packs scalars in order.
struct UniDef { std::string type, name, source, fallback; int offset = -1, count = 1; };
struct PassDef { std::string name, vs, ps, rt; };

static DXGI_FORMAT parseFormat(const std::string& s) {
    if (s == "R8_UNORM")              return DXGI_FORMAT_R8_UNORM;
    if (s == "R16_FLOAT")             return DXGI_FORMAT_R16_FLOAT;
    if (s == "R32_FLOAT")             return DXGI_FORMAT_R32_FLOAT;
    if (s == "R8G8_UNORM")            return DXGI_FORMAT_R8G8_UNORM;
    if (s == "R16G16_FLOAT")          return DXGI_FORMAT_R16G16_FLOAT;
    if (s == "R32G32_FLOAT")          return DXGI_FORMAT_R32G32_FLOAT;
    if (s == "R8G8B8A8_UNORM")        return DXGI_FORMAT_R8G8B8A8_UNORM;
    if (s == "R16G16B16A16_FLOAT")    return DXGI_FORMAT_R16G16B16A16_FLOAT;
    if (s == "R32G32B32A32_FLOAT")    return DXGI_FORMAT_R32G32B32A32_FLOAT;
    die(("unknown format " + s).c_str());
    return DXGI_FORMAT_UNKNOWN;
}

struct Manifest {
    UINT width = 0, height = 0;
    std::vector<TexDef> textures;
    std::vector<SamDef> samplers;
    std::vector<SamState> samplerStatesDef;
    std::vector<UniDef> uniforms;
    std::vector<PassDef> passes;
};

static Manifest loadManifest(const std::string& path) {
    std::ifstream f(path);
    if (!f) die(("cannot open manifest " + path).c_str());
    Manifest m; std::string line;
    while (std::getline(f, line)) {
        std::istringstream ls(line); std::string tag; ls >> tag;
        if (tag == "SIZE") { ls >> m.width >> m.height; }
        else if (tag == "TEX") {
            TexDef t; std::string kind, fmt;
            ls >> t.name >> kind >> t.w >> t.h >> fmt >> t.mips >> t.source;
            t.backbuffer = (kind == "BACKBUFFER");
            t.fmt = parseFormat(fmt);
            if (t.source == "-") t.source.clear();
            m.textures.push_back(t);
        } else if (tag == "SAMSTATE") {
            int idx; SamState st;
            ls >> idx >> st.mn >> st.mg >> st.mp >> st.au >> st.av;
            if ((int)m.samplerStatesDef.size() <= idx)
                m.samplerStatesDef.resize(idx + 1);
            m.samplerStatesDef[idx] = st;
        } else if (tag == "SAM") {
            SamDef s; ls >> s.name >> s.tex >> s.state;
            m.samplers.push_back(s);
        } else if (tag == "UNI") {
            UniDef u; ls >> u.type >> u.name >> u.source >> u.fallback;
            if (!(ls >> u.offset >> u.count)) { u.offset = -1; u.count = 1; }
            if (u.offset < 0) u.offset = (int)m.uniforms.size();
            if (u.source == "-") u.source.clear();
            m.uniforms.push_back(u);
        } else if (tag == "PASS") {
            PassDef p; ls >> p.name >> p.vs >> p.ps >> p.rt;
            if (p.rt == "-") p.rt.clear();
            m.passes.push_back(p);
        }
    }
    return m;
}

// Read a ReShade preset .ini. Only the key=value pairs matter here; the section
// header is ignored so a preset for any effect name loads the same way.
static std::map<std::string, std::string> loadParams(const std::string& path) {
    std::map<std::string, std::string> out;
    std::ifstream f(path);
    if (!f) die(("cannot open params " + path).c_str());
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '[' || line[0] == ';') continue;
        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string k = line.substr(0, eq), v = line.substr(eq + 1);
        while (!k.empty() && isspace((unsigned char)k.back())) k.pop_back();
        while (!v.empty() && isspace((unsigned char)v.back())) v.pop_back();
        out[k] = v;
    }
    return out;
}


static std::vector<uint8_t> loadPng(const std::wstring& path, UINT& w, UINT& h) {
    Rel<IWICImagingFactory> fac;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&fac)))) die("WIC factory failed");
    Rel<IWICBitmapDecoder> dec;
    if (FAILED(fac->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
                                              WICDecodeMetadataCacheOnDemand, &dec)))
        die("cannot open image");
    Rel<IWICBitmapFrameDecode> frame;
    if (FAILED(dec->GetFrame(0, &frame))) die("no frame in image");
    Rel<IWICFormatConverter> conv;
    fac->CreateFormatConverter(&conv);
    if (FAILED(conv->Initialize(frame, GUID_WICPixelFormat32bppRGBA,
                                WICBitmapDitherTypeNone, nullptr, 0.0,
                                WICBitmapPaletteTypeCustom)))
        die("cannot convert image to RGBA8");
    conv->GetSize(&w, &h);
    std::vector<uint8_t> px((size_t)w * h * 4);
    if (FAILED(conv->CopyPixels(nullptr, w * 4, (UINT)px.size(), px.data())))
        die("CopyPixels failed");
    return px;
}

static void savePng(const std::wstring& path, const uint8_t* px, UINT w, UINT h,
                    UINT stride) {
    Rel<IWICImagingFactory> fac;
    CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                     IID_PPV_ARGS(&fac));
    Rel<IWICStream> stream; fac->CreateStream(&stream);
    if (FAILED(stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE)))
        die("cannot create output file");
    Rel<IWICBitmapEncoder> enc;
    fac->CreateEncoder(GUID_ContainerFormatPng, nullptr, &enc);
    enc->Initialize(stream, WICBitmapEncoderNoCache);
    Rel<IWICBitmapFrameEncode> frame; IPropertyBag2* props = nullptr;
    enc->CreateNewFrame(&frame, &props);
    frame->Initialize(props);
    if (props) props->Release();
    frame->SetSize(w, h);
    // No alpha: the effect keeps working state in the render target's alpha,
    // not transparency.
    WICPixelFormatGUID fmt = GUID_WICPixelFormat24bppBGR;
    frame->SetPixelFormat(&fmt);
    const UINT rowBytes = w * 3;
    std::vector<uint8_t> buf((size_t)rowBytes * h);
    for (UINT y = 0; y < h; ++y)
        for (UINT x = 0; x < w; ++x) {
            const uint8_t* s = px + (size_t)y * stride + x * 4;   // RGBA source
            uint8_t* d = buf.data() + (size_t)y * rowBytes + x * 3;
            d[0] = s[2]; d[1] = s[1]; d[2] = s[0];                 // BGR out
        }
    frame->WritePixels(h, rowBytes, (UINT)buf.size(), buf.data());
    frame->Commit();
    enc->Commit();
}

// An HDR capture: float32 RGB in nits, rows bottom to top. The float back
// buffer holds scRGB, where 1.0 is 80 nits, as half floats.
static std::vector<uint16_t> loadPfmAsScRgb(const std::string& path, UINT& w, UINT& h) {
    using DirectX::PackedVector::XMConvertFloatToHalf;
    std::ifstream f(path, std::ios::binary);
    if (!f) die(("cannot open " + path).c_str());
    std::string magic; double scale = 0.0;
    f >> magic >> w >> h >> scale;
    f.get();   // the single whitespace byte that ends the header
    if (magic != "PF") die("only three channel PFM (PF) is supported");
    if (scale > 0.0) die("big endian PFM is not supported");
    std::vector<float> raw((size_t)w * h * 3);
    f.read(reinterpret_cast<char*>(raw.data()), (std::streamsize)(raw.size() * 4));
    if (!f) die(("truncated PFM " + path).c_str());
    std::vector<uint16_t> px((size_t)w * h * 4);
    for (UINT y = 0; y < h; ++y)
        for (UINT x = 0; x < w; ++x) {
            const float* s = raw.data() + ((size_t)(h - 1 - y) * w + x) * 3;
            uint16_t* d = px.data() + ((size_t)y * w + x) * 4;
            for (int c = 0; c < 3; ++c) d[c] = XMConvertFloatToHalf(s[c] / 80.0f);
            d[3] = XMConvertFloatToHalf(1.0f);
        }
    return px;
}

// Stands in for DWM showing a half float swap chain on an SDR display: clip to
// [0, 1] and round to 8 bits, encoding with the sRGB piecewise curve first when
// the swap chain's colour space is scRGB. A game that turns HDR on through the
// GPU driver never sets the colour space, and DWM then shows the values as sRGB
// code values as they are; --present code selects that. Both were checked
// against desktop duplication captures.
static uint8_t scRgbToSrgb8(float v, bool encode) {
    if (!(v > 0.0f)) v = 0.0f;   // also catches NaN
    if (v > 1.0f) v = 1.0f;
    if (encode) v = v <= 0.0031308f ? v * 12.92f : 1.055f * std::pow(v, 1.0f / 2.4f) - 0.055f;
    return (uint8_t)std::lround(v * 255.0f);
}


struct Res {
    Rel<ID3D11Texture2D> tex;
    Rel<ID3D11ShaderResourceView> srv;
    std::vector<ID3D11RenderTargetView*> rtv;   // mip 0 only; GenerateMips fills the rest
    UINT w = 0, h = 0, mips = 1;
};

int wmain(int argc, wchar_t** argv) {
    std::wstring hlslPath, manifestPath, paramsPath, inPath, outPath,
                 noisePath, batchPath;
    int frames = 0;
    std::wstring adapterOpt;
    bool presentLinear = true;   // --present linear (scRGB) or code (colour space never set)
    for (int i = 1; i + 1 < argc; i += 2) {
        std::wstring k = argv[i], v = argv[i + 1];
        if (k == L"--hlsl") hlslPath = v;
        else if (k == L"--manifest") manifestPath = v;
        else if (k == L"--params") paramsPath = v;
        else if (k == L"--in") inPath = v;
        else if (k == L"--out") outPath = v;
        else if (k == L"--noise") noisePath = v;
        else if (k == L"--frames") frames = _wtoi(v.c_str());
        else if (k == L"--batch") batchPath = v;
        else if (k == L"--adapter") adapterOpt = v;
        else if (k == L"--present") {
            if (v != L"linear" && v != L"code") die("--present takes linear or code");
            presentLinear = v == L"linear";
        }
    }
    if (hlslPath.empty() || manifestPath.empty() ||
        (batchPath.empty() && (inPath.empty() || outPath.empty())))
        die("usage:\n"
            "  fxshot --hlsl effect.hlsl --manifest manifest.txt --params preset.ini --in IN --out OUT [options]\n"
            "  fxshot --hlsl effect.hlsl --manifest manifest.txt --batch jobs.txt [options]\n"
            "\n"
            "IN is a .png, or a .pfm of linear nits for an effect translated with --color-space 2.\n"
            "OUT is a .png, or a .pfm for the float swap chain in nits.\n"
            "\n"
            "options:\n"
            "  --batch FILE          one job per line: preset.ini<TAB>input<TAB>output\n"
            "  --noise FILE          image for the texture declared with source = \"...\"\n"
            "  --frames N            frames run per image, default 40\n"
            "  --adapter N|NAME      GPU by index or part of its name, default the one with most video memory\n"
            "  --present linear|code scRGB to PNG: sRGB encode as Windows does (linear, default),\n"
            "                        or write the values as they are (code)");

    setvbuf(stderr, nullptr, _IONBF, 0);
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    auto narrow = [](const std::wstring& w) -> std::string {
        if (w.empty()) return std::string();
        int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(),
                                    nullptr, 0, nullptr, nullptr);
        std::string s((size_t)n, '\0');
        WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n,
                            nullptr, nullptr);
        return s;
    };
    auto widen = [](const std::string& s) -> std::wstring {
        if (s.empty()) return std::wstring();
        int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
        std::wstring w((size_t)n, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
        return w;
    };

    if (getenv("FXSHOT_TRACE")) fprintf(stderr, "[trace] MANIFEST\n");
    Manifest man = loadManifest(narrow(manifestPath));

    // A run is a list of jobs so a parameter sweep pays for device creation and
    // shader compilation once instead of once per image.
    struct Job { std::string params, in, out; };
    std::vector<Job> jobs;
    if (!batchPath.empty()) {
        std::ifstream bf(narrow(batchPath));
        if (!bf) die("cannot open batch file");
        std::string line;
        while (std::getline(bf, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty() || line[0] == '#') continue;
            size_t a = line.find('\t'), b = line.rfind('\t');
            if (a == std::string::npos || a == b)
                die("batch lines must be: params<TAB>input<TAB>output");
            jobs.push_back({line.substr(0, a), line.substr(a + 1, b - a - 1),
                            line.substr(b + 1)});
        }
    } else {
        jobs.push_back({narrow(paramsPath), narrow(inPath), narrow(outPath)});
    }
    if (jobs.empty()) die("no jobs to run");

    if (getenv("FXSHOT_TRACE")) fprintf(stderr, "[trace] DEVICE\n");
    Rel<ID3D11Device> dev; Rel<ID3D11DeviceContext> ctx;
    D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0;
    const bool wantDebug = getenv("FXSHOT_DEBUG") != nullptr;

    // A null adapter gets DXGI's first one, which on any board with integrated
    // graphics is the iGPU. Pick the most dedicated video memory instead.
    // --adapter overrides with an index or a substring of the description.
    Rel<IDXGIFactory1> factory;
    Rel<IDXGIAdapter1> chosen;
    if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
        int pickIdx = -1;
        SIZE_T bestVram = 0;
        for (UINT i = 0;; i++) {
            Rel<IDXGIAdapter1> cand;
            if (factory->EnumAdapters1(i, &cand) == DXGI_ERROR_NOT_FOUND) break;
            DXGI_ADAPTER_DESC1 d{};
            cand->GetDesc1(&d);
            if (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
            if (getenv("FXSHOT_TRACE"))
                fprintf(stderr, "[trace] adapter %u: %ls (%zu MB)\n", i,
                        d.Description, (size_t)(d.DedicatedVideoMemory >> 20));
            if (!adapterOpt.empty()) {
                const bool hit = iswdigit(adapterOpt[0])
                    ? (UINT)_wtoi(adapterOpt.c_str()) == i
                    : std::wstring(d.Description).find(adapterOpt) != std::wstring::npos;
                if (hit) { pickIdx = (int)i; break; }
            } else if (d.DedicatedVideoMemory > bestVram) {
                bestVram = d.DedicatedVideoMemory;
                pickIdx = (int)i;
            }
        }
        if (!adapterOpt.empty() && pickIdx < 0) die("no adapter matched --adapter");
        if (pickIdx >= 0) factory->EnumAdapters1((UINT)pickIdx, &chosen);
    }
    if (chosen) {
        DXGI_ADAPTER_DESC1 d{};
        chosen->GetDesc1(&d);
        fprintf(stderr, "fxshot: rendering on %ls (%zu MB)\n", d.Description,
                (size_t)(d.DedicatedVideoMemory >> 20));
    }
    // A specific adapter has to be paired with D3D_DRIVER_TYPE_UNKNOWN.
    IDXGIAdapter1* ad = chosen;
    const D3D_DRIVER_TYPE dt = ad ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE;
    HRESULT hr = E_FAIL;
    if (wantDebug)
        hr = D3D11CreateDevice(ad, dt, nullptr, D3D11_CREATE_DEVICE_DEBUG, &fl, 1,
                               D3D11_SDK_VERSION, &dev, nullptr, &ctx);
    if (FAILED(hr))
        hr = D3D11CreateDevice(ad, dt, nullptr, 0, &fl, 1,
                               D3D11_SDK_VERSION, &dev, nullptr, &ctx);
    if (FAILED(hr) && ad)   // fall back rather than refuse to run
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &fl, 1,
                               D3D11_SDK_VERSION, &dev, nullptr, &ctx);
    if (FAILED(hr)) dieHr("D3D11CreateDevice failed", hr);

    // Without draining the debug layer, a misconfigured pass renders nothing
    // and the reason goes nowhere.
    Rel<ID3D11InfoQueue> infoQueue;
    if (wantDebug) dev->QueryInterface(IID_PPV_ARGS(&infoQueue));
    auto drain = [&]() {
        if (!infoQueue.p) return;
        UINT64 n = infoQueue->GetNumStoredMessages();
        for (UINT64 i = 0; i < n; ++i) {
            SIZE_T len = 0;
            infoQueue->GetMessage(i, nullptr, &len);
            std::vector<char> buf(len);
            auto* msg = (D3D11_MESSAGE*)buf.data();
            if (SUCCEEDED(infoQueue->GetMessage(i, msg, &len)))
                fprintf(stderr, "[d3d] %.*s\n", (int)msg->DescriptionByteLength,
                        msg->pDescription);
        }
        infoQueue->ClearStoredMessages();
    };

    if (getenv("FXSHOT_TRACE")) fprintf(stderr, "[trace] SHADERS\n");
    std::ifstream hf(narrow(hlslPath));
    if (!hf) die("cannot open hlsl");
    std::stringstream hs; hs << hf.rdbuf();
    std::string source = hs.str();

    auto compile = [&](const char* entry, const char* target) -> ID3DBlob* {
        ID3DBlob *code = nullptr, *err = nullptr;
        HRESULT r = D3DCompile(source.data(), source.size(), narrow(hlslPath).c_str(),
                               nullptr, D3D_COMPILE_STANDARD_FILE_INCLUDE, entry,
                               target, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &err);
        if (FAILED(r)) {
            fprintf(stderr, "fxshot: compiling %s failed:\n%s\n", entry,
                    err ? (const char*)err->GetBufferPointer() : "(no message)");
            exit(1);
        }
        if (err) err->Release();
        return code;
    };

    // One vertex shader per distinct name. Effects normally share a single
    // full-screen pass, but nothing in ReShade FX requires that.
    std::map<std::string, ID3D11VertexShader*> vertexShaders;
    for (auto& p : man.passes) {
        if (p.vs.empty() || vertexShaders.count(p.vs)) continue;
        ID3DBlob* b = compile(p.vs.c_str(), "vs_5_0");
        ID3D11VertexShader* vs = nullptr;
        if (FAILED(dev->CreateVertexShader(b->GetBufferPointer(),
                                           b->GetBufferSize(), nullptr, &vs)))
            die(("CreateVertexShader failed for " + p.vs).c_str());
        b->Release();
        vertexShaders[p.vs] = vs;
    }

    std::map<std::string, ID3D11PixelShader*> pixelShaders;
    for (auto& p : man.passes) {
        if (pixelShaders.count(p.ps)) continue;
        ID3DBlob* b = compile(p.ps.c_str(), "ps_5_0");
        ID3D11PixelShader* ps = nullptr;
        if (FAILED(dev->CreatePixelShader(b->GetBufferPointer(),
                                          b->GetBufferSize(), nullptr, &ps)))
            die(("CreatePixelShader failed for " + p.ps).c_str());
        b->Release();
        pixelShaders[p.ps] = ps;
    }

    if (getenv("FXSHOT_TRACE")) fprintf(stderr, "[trace] TEXTURES\n");
    std::map<std::string, Res> res;
    for (auto& t : man.textures) {
        Res r; r.w = t.backbuffer ? man.width : t.w;
        r.h = t.backbuffer ? man.height : t.h;
        r.mips = t.backbuffer ? 1 : t.mips;
        // ReShade refuses a texture that asks for more mip levels than its size
        // allows ("Failed to create texture"), so fail the same way here rather
        // than render an effect the game will not load.
        int fullChain = 1;
        for (UINT s = (UINT)std::max<int>(r.w, r.h); s > 1; s >>= 1) ++fullChain;
        if (r.mips > fullChain) {
            fprintf(stderr, "fxshot: texture %s asks for %d mip levels, but %dx%d allows %d; "
                            "ReShade fails to create it\n", t.name.c_str(), r.mips, r.w, r.h, fullChain);
            exit(1);
        }
        D3D11_TEXTURE2D_DESC d{};
        d.Width = r.w; d.Height = r.h; d.MipLevels = r.mips; d.ArraySize = 1;
        d.Format = t.fmt;
        d.SampleDesc.Count = 1; d.Usage = D3D11_USAGE_DEFAULT;
        d.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
        if (r.mips > 1) d.MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS;
        if (FAILED(dev->CreateTexture2D(&d, nullptr, &r.tex)))
            die(("CreateTexture2D failed for " + t.name).c_str());
        if (FAILED(dev->CreateShaderResourceView(r.tex, nullptr, &r.srv)))
            die(("CreateShaderResourceView failed for " + t.name).c_str());
        ID3D11RenderTargetView* rtv = nullptr;
        D3D11_RENDER_TARGET_VIEW_DESC rd{};
        rd.Format = d.Format; rd.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
        rd.Texture2D.MipSlice = 0;
        if (FAILED(dev->CreateRenderTargetView(r.tex, &rd, &rtv)))
            die(("CreateRenderTargetView failed for " + t.name).c_str());
        r.rtv.push_back(rtv);
        res[t.name] = std::move(r);
    }

    // File textures are the same for every job, so upload them once.
    for (auto& t : man.textures) {
        if (!t.backbuffer && !t.source.empty() && !noisePath.empty()) {
            UINT nw, nh;
            std::vector<uint8_t> npx = loadPng(noisePath, nw, nh);
            if (nw != t.w || nh != t.h) die("noise texture size mismatch");
            ctx->UpdateSubresource(res[t.name].tex, 0, nullptr, npx.data(), nw * 4, 0);
        }
    }

    if (getenv("FXSHOT_TRACE")) fprintf(stderr, "[trace] SAMPLERS\n");
    std::vector<ID3D11SamplerState*> samplerStates;
    for (auto& s : man.samplerStatesDef) {
        D3D11_SAMPLER_DESC sd{};
        bool pointMin = s.mn == "POINT", pointMag = s.mg == "POINT",
             pointMip = s.mp == "POINT";
        // D3D has no per-axis mix beyond these combinations; ReShade effects only
        // ever use all-point or all-linear, which map exactly.
        sd.Filter = (pointMin && pointMag && pointMip)
                        ? D3D11_FILTER_MIN_MAG_MIP_POINT
                        : D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        auto addr = [](const std::string& a) {
            if (a == "WRAP" || a == "REPEAT") return D3D11_TEXTURE_ADDRESS_WRAP;
            if (a == "MIRROR") return D3D11_TEXTURE_ADDRESS_MIRROR;
            if (a == "BORDER") return D3D11_TEXTURE_ADDRESS_BORDER;
            return D3D11_TEXTURE_ADDRESS_CLAMP;
        };
        sd.AddressU = addr(s.au); sd.AddressV = addr(s.av);
        sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
        sd.MaxLOD = D3D11_FLOAT32_MAX;
        ID3D11SamplerState* ss = nullptr;
        if (FAILED(dev->CreateSamplerState(&sd, &ss)))
            die("CreateSamplerState failed");
        samplerStates.push_back(ss);
    }
    // Texture slots follow the declaration order of the FX samplers, matching
    // the register(tN) assignments the translator emitted.
    std::vector<std::string> samplerTex;
    for (auto& s : man.samplers) samplerTex.push_back(s.tex);

    if (getenv("FXSHOT_TRACE")) fprintf(stderr, "[trace] CBUFFER\n");
    size_t cbSlots = 0;
    for (auto& u : man.uniforms) cbSlots = std::max(cbSlots, (size_t)(u.offset + u.count));
    std::vector<uint32_t> cb(cbSlots, 0);
    size_t frameTimeIdx = SIZE_MAX, frameCountIdx = SIZE_MAX;
    for (size_t i = 0; i < man.uniforms.size(); ++i) {
        const UniDef& u = man.uniforms[i];
        if (u.source == "frametime")  frameTimeIdx = u.offset;
        if (u.source == "framecount") frameCountIdx = u.offset;
    }
    auto applyParams = [&](const std::string& path) {
        auto params = loadParams(path);
        for (size_t i = 0; i < man.uniforms.size(); ++i) {
            const UniDef& u = man.uniforms[i];
            if (!u.source.empty()) continue;

            // A preset older than the effect lacks its newer uniforms, and
            // ReShade falls back to the declared default. Say so, because a
            // mistyped key looks exactly like an omission.
            std::string value;
            auto it = params.find(u.name);
            if (it != params.end()) {
                value = it->second;
            } else if (!u.fallback.empty() && u.fallback != "-") {
                value = u.fallback;
                fprintf(stderr, "fxshot: %s omits %s, using the effect default %s\n",
                        path.c_str(), u.name.c_str(), u.fallback.c_str());
            } else {
                fprintf(stderr, "fxshot: %s has no value for uniform %s and the "
                                "effect declares no default\n",
                        path.c_str(), u.name.c_str());
                exit(1);
            }

            // Vector components arrive comma separated, as ReShade writes them.
            const char* at = value.c_str();
            for (int c = 0; c < u.count; ++c) {
                char* end = nullptr;
                if (u.type == "float") { float v = strtof(at, &end); memcpy(&cb[u.offset + c], &v, 4); }
                else { int v = (int)strtol(at, &end, 10); memcpy(&cb[u.offset + c], &v, 4); }
                at = end;
                while (*at == ',' || *at == ' ') ++at;
            }
        }
    };
    D3D11_BUFFER_DESC bd{};
    bd.ByteWidth = (UINT)((cb.size() * 4 + 15) / 16 * 16);
    bd.Usage = D3D11_USAGE_DYNAMIC; bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    Rel<ID3D11Buffer> cbuf;
    if (FAILED(dev->CreateBuffer(&bd, nullptr, &cbuf))) die("cbuffer failed");

    if (getenv("FXSHOT_TRACE")) fprintf(stderr, "[trace] RENDERLOOP\n");
    ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ctx->IASetInputLayout(nullptr);

    // Pin the fixed-function state rather than inheriting defaults: the
    // full-screen triangle deliberately extends past the viewport, so culling
    // and depth clipping both have to be off for it to cover the target.
    Rel<ID3D11RasterizerState> rast;
    {
        D3D11_RASTERIZER_DESC rd{};
        rd.FillMode = D3D11_FILL_SOLID;
        rd.CullMode = D3D11_CULL_NONE;
        rd.DepthClipEnable = FALSE;
        rd.ScissorEnable = FALSE;
        if (FAILED(dev->CreateRasterizerState(&rd, &rast)))
            die("CreateRasterizerState failed");
        ctx->RSSetState(rast);
    }
    Rel<ID3D11BlendState> blend;
    {
        D3D11_BLEND_DESC bs{};
        bs.RenderTarget[0].BlendEnable = FALSE;
        bs.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
        if (FAILED(dev->CreateBlendState(&bs, &blend)))
            die("CreateBlendState failed");
        float bf[4] = {0, 0, 0, 0};
        ctx->OMSetBlendState(blend, bf, 0xffffffff);
    }
    Rel<ID3D11DepthStencilState> depth;
    {
        D3D11_DEPTH_STENCIL_DESC dsd{};
        dsd.DepthEnable = FALSE;
        dsd.StencilEnable = FALSE;
        if (FAILED(dev->CreateDepthStencilState(&dsd, &depth)))
            die("CreateDepthStencilState failed");
        ctx->OMSetDepthStencilState(depth, 0);
    }

    // The manifest carries the swap chain format. A float one means scRGB: the
    // input is an HDR capture and the output goes through scRgbToSrgb8.
    DXGI_FORMAT bbFmt = DXGI_FORMAT_R8G8B8A8_UNORM;
    for (auto& t : man.textures)
        if (t.backbuffer) bbFmt = t.fmt;
    const bool scRgb = bbFmt == DXGI_FORMAT_R16G16B16A16_FLOAT;

    // The Present pass targets the backbuffer; give it its own surface so the
    // source image stays intact for every frame, exactly as a game would supply
    // a fresh frame each time.
    Res out;
    {
        D3D11_TEXTURE2D_DESC d{};
        d.Width = man.width; d.Height = man.height; d.MipLevels = 1; d.ArraySize = 1;
        d.Format = bbFmt; d.SampleDesc.Count = 1;
        d.Usage = D3D11_USAGE_DEFAULT;
        d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        if (FAILED(dev->CreateTexture2D(&d, nullptr, &out.tex)))
            die("output texture creation failed");
        ID3D11RenderTargetView* rtv = nullptr;
        if (FAILED(dev->CreateRenderTargetView(out.tex, nullptr, &rtv)))
            die("output RTV creation failed");
        out.rtv.push_back(rtv);
        out.w = man.width; out.h = man.height;
    }

    D3D11_TEXTURE2D_DESC sd{};
    sd.Width = man.width; sd.Height = man.height; sd.MipLevels = 1; sd.ArraySize = 1;
    sd.Format = bbFmt; sd.SampleDesc.Count = 1;
    sd.Usage = D3D11_USAGE_STAGING; sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    Rel<ID3D11Texture2D> staging;
    if (FAILED(dev->CreateTexture2D(&sd, nullptr, &staging)))
        die("staging texture failed");

    if (frames <= 0) frames = 40;   // adaptation settles well inside this

    for (size_t job = 0; job < jobs.size(); ++job) {
    const Job& J = jobs[job];
    applyParams(J.params);

    UINT iw, ih;
    std::vector<uint8_t> input;
    std::vector<uint16_t> inputHalf;
    if (scRgb) inputHalf = loadPfmAsScRgb(J.in, iw, ih);
    else       input = loadPng(widen(J.in), iw, ih);
    if (iw != man.width || ih != man.height) {
        fprintf(stderr, "fxshot: %s is %ux%u but the effect was translated for "
                        "%ux%u; retranslate at the image size\n",
                J.in.c_str(), iw, ih, man.width, man.height);
        return 1;
    }
    for (auto& t : man.textures)
        if (t.backbuffer)
            ctx->UpdateSubresource(res[t.name].tex, 0, nullptr,
                                   scRgb ? (const void*)inputHalf.data() : input.data(),
                                   man.width * (scRgb ? 8 : 4), 0);

    // Clear every intermediate so temporal state (the adaptation history) does
    // not leak from the previous job and bias this one's settling.
    const float zero[4] = {0, 0, 0, 0};
    for (auto& t : man.textures)
        if (!t.backbuffer && t.source.empty())
            ctx->ClearRenderTargetView(res[t.name].rtv[0], zero);

    for (int frame = 0; frame < frames; ++frame) {
        D3D11_MAPPED_SUBRESOURCE ms;
        ctx->Map(cbuf, 0, D3D11_MAP_WRITE_DISCARD, 0, &ms);
        if (frameTimeIdx != SIZE_MAX) { float ft = 16.6667f;
                                        memcpy(&cb[frameTimeIdx], &ft, 4); }
        if (frameCountIdx != SIZE_MAX) { int fc = frame;
                                         memcpy(&cb[frameCountIdx], &fc, 4); }
        memcpy(ms.pData, cb.data(), cb.size() * 4);
        ctx->Unmap(cbuf, 0);
        ctx->PSSetConstantBuffers(0, 1, &cbuf.p);

        for (auto& p : man.passes) {
            if (getenv("FXSHOT_TRACE") && frame == 0)
                fprintf(stderr, "[pass] %s -> %s\n", p.name.c_str(),
                        p.rt.empty() ? "BACKBUFFER" : p.rt.c_str());
            if (!p.rt.empty() && res.find(p.rt) == res.end())
                die(("pass targets unknown texture " + p.rt).c_str());
            if (pixelShaders[p.ps] == nullptr)
                die(("no compiled shader for " + p.ps).c_str());

            ID3D11RenderTargetView* rtv =
                p.rt.empty() ? out.rtv[0] : res[p.rt].rtv[0];
            UINT rw = p.rt.empty() ? out.w : res[p.rt].w;
            UINT rh = p.rt.empty() ? out.h : res[p.rt].h;

            // A resource cannot be read and written in the same pass, so drop any
            // SRV that aliases this pass's target before binding the target.
            std::vector<ID3D11ShaderResourceView*> srvs(samplerTex.size(), nullptr);
            for (size_t i = 0; i < samplerTex.size(); ++i)
                if (p.rt.empty() || samplerTex[i] != p.rt)
                    srvs[i] = res[samplerTex[i]].srv;

            if (getenv("FXSHOT_TRACE") && frame == 0) fprintf(stderr, "   [unbind]\n");
            ID3D11RenderTargetView* nullRtv[1] = {nullptr};
            ctx->OMSetRenderTargets(1, nullRtv, nullptr);
            if (getenv("FXSHOT_TRACE") && frame == 0) fprintf(stderr, "   [srvs]\n");
            ctx->PSSetShaderResources(0, (UINT)srvs.size(), srvs.data());
            if (getenv("FXSHOT_TRACE") && frame == 0) fprintf(stderr, "   [samplers]\n");
            ctx->PSSetSamplers(0, (UINT)samplerStates.size(), samplerStates.data());
            if (getenv("FXSHOT_TRACE") && frame == 0) fprintf(stderr, "   [setrt]\n");
            ctx->OMSetRenderTargets(1, &rtv, nullptr);

            D3D11_VIEWPORT vp{0.0f, 0.0f, (float)rw, (float)rh, 0.0f, 1.0f};
            if (getenv("FXSHOT_TRACE") && frame == 0) fprintf(stderr, "   [viewport]\n");
            ctx->RSSetViewports(1, &vp);
            if (getenv("FXSHOT_TRACE") && frame == 0) fprintf(stderr, "   [setps]\n");
            ctx->VSSetShader(vertexShaders[p.vs], nullptr, 0);
            ctx->PSSetShader(pixelShaders[p.ps], nullptr, 0);
            if (getenv("FXSHOT_TRACE") && frame == 0) fprintf(stderr, "   [draw]\n");
            ctx->Draw(3, 0);

            // ReShade regenerates mips for any render target that declares them.
            if (!p.rt.empty() && res[p.rt].mips > 1)
                ctx->GenerateMips(res[p.rt].srv);
        }
        if (frame == 0) drain();
    }

    if (getenv("FXSHOT_TRACE")) fprintf(stderr, "[trace] READBACK\n");
    ctx->CopyResource(staging, out.tex);
    D3D11_MAPPED_SUBRESOURCE rb;
    if (FAILED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &rb))) die("map failed");
    const bool pfmOut = J.out.size() > 4 && J.out.compare(J.out.size() - 4, 4, ".pfm") == 0;
    if (scRgb && pfmOut) {
        // The swap chain as it is, in nits, to measure what 8 bits round away.
        using DirectX::PackedVector::XMConvertHalfToFloat;
        std::ofstream f(J.out, std::ios::binary);
        if (!f) die(("cannot create " + J.out).c_str());
        f << "PF\n" << man.width << " " << man.height << "\n-1.0\n";
        std::vector<float> row((size_t)man.width * 3);
        for (UINT y = man.height; y-- > 0;) {
            const uint16_t* s = (const uint16_t*)((const uint8_t*)rb.pData + (size_t)y * rb.RowPitch);
            for (UINT x = 0; x < man.width; ++x)
                for (int c = 0; c < 3; ++c)
                    row[(size_t)x * 3 + c] = XMConvertHalfToFloat(s[x * 4 + c]) * 80.0f;
            f.write(reinterpret_cast<const char*>(row.data()), (std::streamsize)(row.size() * 4));
        }
    } else if (scRgb) {
        using DirectX::PackedVector::XMConvertHalfToFloat;
        std::vector<uint8_t> px((size_t)man.width * man.height * 4);
        for (UINT y = 0; y < man.height; ++y) {
            const uint16_t* s = (const uint16_t*)((const uint8_t*)rb.pData + (size_t)y * rb.RowPitch);
            for (UINT x = 0; x < man.width * 4; ++x)
                px[(size_t)y * man.width * 4 + x] = scRgbToSrgb8(XMConvertHalfToFloat(s[x]), presentLinear);
        }
        savePng(widen(J.out), px.data(), man.width, man.height, man.width * 4);
    } else {
        savePng(widen(J.out), (const uint8_t*)rb.pData, man.width, man.height,
                rb.RowPitch);
    }
    ctx->Unmap(staging, 0);
    if (jobs.size() > 1)
        fprintf(stderr, "[%zu/%zu] %s\n", job + 1, jobs.size(), J.out.c_str());
    }   // end job loop

    for (auto& kv : pixelShaders) kv.second->Release();
    for (auto& kv : vertexShaders) kv.second->Release();
    for (auto* s : samplerStates) s->Release();
    for (auto& kv : res) for (auto* r : kv.second.rtv) r->Release();
    for (auto* r : out.rtv) r->Release();
    return 0;
}
