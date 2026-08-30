// Copyright (c) Aimes Soft and contributors.
// SPDX-License-Identifier: MIT

#pragma once

#include <Windows.Foundation.h>
#include <Windows.Graphics.Effects.h>
#include <Windows.Graphics.Effects.Interop.h>
#include <d2d1effects.h>
#include <wrl.h>
#include <wrl/wrappers/corewrappers.h>

namespace erika_flutter {

// Windows.UI.Composition consumes a Win2D-style effect description.  The SDK
// does not ship a concrete C++ BlendEffect class, so keep the small descriptor
// here rather than attaching IDCompositionBlendEffect directly to a visual.
// The latter is a filter node whose two inputs must belong to an explicit
// filter graph; treating the HWND target as an implicit input produces an
// invalid D2D graph inside DWM.
class ErikaCompositionBlendEffect final
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<
              Microsoft::WRL::WinRtClassicComMix>,
          ABI::Windows::Graphics::Effects::IGraphicsEffect,
          ABI::Windows::Graphics::Effects::IGraphicsEffectSource,
          ABI::Windows::Graphics::Effects::IGraphicsEffectD2D1Interop> {
  InspectableClass(L"Erika.CompositionBlendEffect", BaseTrust);

 public:
  HRESULT RuntimeClassInitialize(
      ABI::Windows::Graphics::Effects::IGraphicsEffectSource* background,
      ABI::Windows::Graphics::Effects::IGraphicsEffectSource* foreground,
      D2D1_BLEND_MODE mode) noexcept {
    if (background == nullptr || foreground == nullptr) {
      return E_INVALIDARG;
    }
    background_ = background;
    foreground_ = foreground;
    mode_ = mode;
    return S_OK;
  }

  IFACEMETHODIMP get_Name(HSTRING* value) override {
    if (value == nullptr) {
      return E_POINTER;
    }
    return name_.CopyTo(value);
  }

  IFACEMETHODIMP put_Name(HSTRING value) override {
    return name_.Set(value);
  }

  IFACEMETHODIMP GetEffectId(GUID* value) override {
    if (value == nullptr) {
      return E_POINTER;
    }
    // CLSID_D2D1Blend, spelled out to keep this descriptor independent from
    // the SDK's external GUID-definition library.
    static constexpr GUID kBlendEffectId{
        0x81C5B77B,
        0x13F8,
        0x4CDD,
        {0xAD, 0x20, 0xC8, 0x90, 0x54, 0x7A, 0xC6, 0x5D}};
    *value = kBlendEffectId;
    return S_OK;
  }

  IFACEMETHODIMP GetNamedPropertyMapping(
      LPCWSTR name,
      UINT* index,
      ABI::Windows::Graphics::Effects::GRAPHICS_EFFECT_PROPERTY_MAPPING*
          mapping) override {
    if (name == nullptr || index == nullptr || mapping == nullptr) {
      return E_POINTER;
    }
    if (_wcsicmp(name, L"Mode") != 0) {
      return E_INVALIDARG;
    }
    *index = D2D1_BLEND_PROP_MODE;
    *mapping = ABI::Windows::Graphics::Effects::
        GRAPHICS_EFFECT_PROPERTY_MAPPING_DIRECT;
    return S_OK;
  }

  IFACEMETHODIMP GetPropertyCount(UINT* count) override {
    if (count == nullptr) {
      return E_POINTER;
    }
    *count = 1;
    return S_OK;
  }

  IFACEMETHODIMP GetProperty(
      UINT index,
      ABI::Windows::Foundation::IPropertyValue** value) override {
    if (value == nullptr) {
      return E_POINTER;
    }
    *value = nullptr;
    if (index != D2D1_BLEND_PROP_MODE) {
      return E_INVALIDARG;
    }

    Microsoft::WRL::ComPtr<ABI::Windows::Foundation::IPropertyValueStatics>
        property_value_factory;
    Microsoft::WRL::Wrappers::HStringReference class_name(
        RuntimeClass_Windows_Foundation_PropertyValue);
    HRESULT result = GetActivationFactory(class_name.Get(),
                                          &property_value_factory);
    if (FAILED(result)) {
      return result;
    }
    return property_value_factory->CreateUInt32(
        static_cast<UINT32>(mode_),
        reinterpret_cast<IInspectable**>(value));
  }

  IFACEMETHODIMP GetSource(
      UINT index,
      ABI::Windows::Graphics::Effects::IGraphicsEffectSource** value) override {
    if (value == nullptr) {
      return E_POINTER;
    }
    if (index == 0) {
      return background_.CopyTo(value);
    }
    if (index == 1) {
      return foreground_.CopyTo(value);
    }
    *value = nullptr;
    return E_INVALIDARG;
  }

  IFACEMETHODIMP GetSourceCount(UINT* count) override {
    if (count == nullptr) {
      return E_POINTER;
    }
    *count = 2;
    return S_OK;
  }

 private:
  Microsoft::WRL::Wrappers::HString name_;
  Microsoft::WRL::ComPtr<
      ABI::Windows::Graphics::Effects::IGraphicsEffectSource>
      background_;
  Microsoft::WRL::ComPtr<
      ABI::Windows::Graphics::Effects::IGraphicsEffectSource>
      foreground_;
  D2D1_BLEND_MODE mode_ = D2D1_BLEND_MODE_OVERLAY;
};

}  // namespace erika_flutter
