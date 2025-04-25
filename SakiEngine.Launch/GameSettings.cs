using System.IO;
// using System.Text.Json;
// using System.Text.Json.Serialization;
using Microsoft.Xna.Framework.Graphics; // For SamplerState
using SkiaSharp; // For SKPaintHinting
using System;

namespace SakiEngine.Launch
{
    public class GameSettings
    {
        // --- Folder Name for AppData ---
        private const string SettingsFolderName = "AimesSoft_SakiEngine";
        private const string SettingsFileName = "settings.bin";

        // --- Display Settings ---
        public int ResolutionWidth { get; set; } = 1920;
        public int ResolutionHeight { get; set; } = 1080;
        public bool IsFullscreen { get; set; } = false;

        // --- Rendering Settings ---
        public float ScaleFactor { get; set; } = 2.0f;
        public SamplerState SamplerState { get; set; } = SamplerState.LinearClamp;

        // --- Font Settings ---
        public bool UseAntialias { get; set; } = true;
        public SKPaintHinting HintingLevel { get; set; } = SKPaintHinting.Full;
        public bool UseSubpixelText { get; set; } = true;

        // --- Static Path Helper (made public) ---
        public static string GetSettingsFilePath()
        {
            string appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            string settingsDirPath = Path.Combine(appDataPath, SettingsFolderName);
            return Path.Combine(settingsDirPath, SettingsFileName);
        }

        // --- Static Load/Save Methods (Binary Format, using string names for enums) ---
        public static GameSettings Load()
        {
            string filePath = GetSettingsFilePath();
            var settings = new GameSettings(); // Start with defaults

            if (!File.Exists(filePath))
            {
                return settings; // Return defaults if file doesn't exist
            }

            try
            {
                using (var stream = File.Open(filePath, FileMode.Open))
                using (var reader = new BinaryReader(stream))
                {
                    // Read properties in the EXACT order they were written
                    settings.ResolutionWidth = reader.ReadInt32();
                    settings.ResolutionHeight = reader.ReadInt32();
                    settings.IsFullscreen = reader.ReadBoolean();
                    settings.ScaleFactor = reader.ReadSingle();
                    // Read SamplerState Name as string
                    string samplerName = reader.ReadString();
                    settings.SamplerState = samplerName switch
                    {
                        "PointClamp" => SamplerState.PointClamp,
                        "LinearClamp" => SamplerState.LinearClamp,
                        "AnisotropicClamp" => SamplerState.AnisotropicClamp,
                        _ => SamplerState.LinearClamp // Default fallback
                    };
                    settings.UseAntialias = reader.ReadBoolean();
                    // Read HintingLevel Name as string
                    string hintingName = reader.ReadString();
                     settings.HintingLevel = hintingName switch
                    {
                        "NoHinting" => SKPaintHinting.NoHinting,
                        "Slight" => SKPaintHinting.Slight,
                        "Normal" => SKPaintHinting.Normal,
                        "Full" => SKPaintHinting.Full,
                        _ => SKPaintHinting.Full // Default fallback
                    };
                    settings.UseSubpixelText = reader.ReadBoolean();
                    
                    // Add future fields here, potentially checking stream position or version
                }
            }
            catch (EndOfStreamException) 
            {
                 Console.WriteLine($"[GameSettings] Warning: Settings file {filePath} is incomplete or from an older version. Using loaded values where possible and defaults otherwise.");
            }
            catch (Exception ex)
            { 
                Console.WriteLine($"[GameSettings] Failed to load settings from {filePath}: {ex.Message}. Using defaults.");
                return new GameSettings(); // Return fresh defaults on error
            }
            return settings;
        }

         public void Save()
         {
             string filePath = GetSettingsFilePath();
             try
             {
                 // Ensure the directory exists
                 string directoryPath = Path.GetDirectoryName(filePath);
                 if (directoryPath != null)
                 {
                     Directory.CreateDirectory(directoryPath);
                 }
                 else
                 {
                      throw new IOException("Could not determine directory path for settings file.");
                 }
 
                 using (var stream = File.Open(filePath, FileMode.Create)) // Use Create to overwrite
                 using (var writer = new BinaryWriter(stream))
                 {
                     // Write properties in a specific, consistent order
                     writer.Write(ResolutionWidth);
                     writer.Write(ResolutionHeight);
                     writer.Write(IsFullscreen);
                     writer.Write(ScaleFactor);
                     
                     // Determine SamplerState Name using if-else if
                     string samplerName;
                     if (SamplerState == SamplerState.PointClamp) samplerName = "PointClamp";
                     else if (SamplerState == SamplerState.LinearClamp) samplerName = "LinearClamp";
                     else if (SamplerState == SamplerState.AnisotropicClamp) samplerName = "AnisotropicClamp";
                     else samplerName = "LinearClamp"; // Default fallback
                     writer.Write(samplerName);
                     
                     writer.Write(UseAntialias);
                     
                     // Determine HintingLevel Name using if-else if
                      string hintingName;
                      if(HintingLevel == SKPaintHinting.NoHinting) hintingName = "NoHinting";
                      else if (HintingLevel == SKPaintHinting.Slight) hintingName = "Slight";
                      else if (HintingLevel == SKPaintHinting.Normal) hintingName = "Normal";
                      else if (HintingLevel == SKPaintHinting.Full) hintingName = "Full";
                      else hintingName = "Full"; // Default fallback
                     writer.Write(hintingName);
                     
                     writer.Write(UseSubpixelText);
                     
                     // Add future fields here
                 }
             }
             catch (Exception ex)
             { 
                 Console.WriteLine($"[GameSettings] Failed to save settings to {filePath}: {ex.Message}.");
             }
         }
     }
}
