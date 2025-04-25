using SakiEngine.Core;

namespace SakiEngine.Launch
{
    /// <summary>
    /// 程序入口
    /// </summary>
    public static class Program
    {
        /// <summary>
        /// 程序主入口点
        /// </summary>
        static void Main(string[] args)
        {
            using var game = new Game1();
            game.Run();
        }
    }
}