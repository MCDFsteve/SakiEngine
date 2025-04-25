using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using System.Collections.Generic;
using System.Linq;

namespace SakiEngine.Core.SceneGraph
{
    /// <summary>
    /// 场景管理器，管理所有场景对象并处理渲染排序
    /// </summary>
    public class SceneManager
    {
        private readonly List<SceneObject> _sceneObjects = new();
        private bool _needsSorting = false;
        
        /// <summary>
        /// 添加场景对象
        /// </summary>
        public void AddObject(SceneObject sceneObject)
        {
            _sceneObjects.Add(sceneObject);
            _needsSorting = true;
        }
        
        /// <summary>
        /// 移除场景对象
        /// </summary>
        public void RemoveObject(SceneObject sceneObject)
        {
            _sceneObjects.Remove(sceneObject);
        }
        
        /// <summary>
        /// 根据ID查找场景对象
        /// </summary>
        public SceneObject? GetObjectById(string id)
        {
            return _sceneObjects.FirstOrDefault(obj => obj.Id == id);
        }
        
        /// <summary>
        /// 清除所有场景对象
        /// </summary>
        public void Clear()
        {
            _sceneObjects.Clear();
        }
        
        /// <summary>
        /// 更新所有场景对象
        /// </summary>
        public void Update(GameTime gameTime)
        {
            var objectsToUpdate = _sceneObjects.ToArray(); // 使用ToArray避免集合修改异常
            // Console.WriteLine($"[SceneManager] Updating {objectsToUpdate.Length} objects..."); // 可选，可能刷屏
            foreach (var obj in objectsToUpdate) 
            {
                // Console.WriteLine($"[SceneManager] ---> Updating object: {obj.Id} ({obj.GetType().Name})"); // 移除日志
                try
                {
                    // 移除错误的 IsActive 检查，直接调用 Update
                    obj.Update(gameTime);
                }
                catch (Exception ex)
                {
                    // Console.WriteLine($"[SceneManager] !!!! EXCEPTION updating object {obj.Id} ({obj.GetType().Name}): {ex.Message}"); // 移除日志
                    // 这里可以考虑更健壮的错误处理，例如记录到文件或禁用对象
                    // 暂时保留 ex 变量，即使未使用，避免产生新的警告
                    _ = ex; // 明确表示忽略 ex，抑制 CS0168 警告
                }
                // Console.WriteLine($"[SceneManager] <--- Finished updating object: {obj.Id}"); // 移除日志
            }
             // Console.WriteLine($"[SceneManager] Finished updating all objects."); // 可选
        }
        
        /// <summary>
        /// 绘制所有场景对象，按层级排序
        /// </summary>
        public void Draw(SpriteBatch spriteBatch, int screenWidth, int screenHeight)
        {
            if (_needsSorting)
            {
                SortObjects();
                _needsSorting = false;
            }
            
            foreach (var obj in _sceneObjects)
            {
                if (obj.Visible)
                {
                    obj.Draw(spriteBatch, screenWidth, screenHeight);
                }
            }
        }
        
        /// <summary>
        /// 按层级排序场景对象
        /// </summary>
        private void SortObjects()
        {
            _sceneObjects.Sort((a, b) => a.LayerId.CompareTo(b.LayerId));
        }
    }
} 