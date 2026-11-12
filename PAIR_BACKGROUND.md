# PelagiVex 选题与研究背景

核对日期为 2026 年 11 月 7 日。身份使用官网自述、本人材料和项目仓库交叉核对。官网的 Zhongjie Huang／黄中杰与本机谢菲尔德硕士论文原件封面署名一致。大学 Gmail 中读到的 CV 附件同时列出姓名、官网域名、本科摄像头分类项目和硕士组织学项目。官网 PelagiVex 案例指向的 GitHub 仓库也与本地 Git 的 `origin` 及 GitHub 插件返回的仓库相同。[官网](https://www.zhongjiehuang.com/) · [教育页](https://www.zhongjiehuang.com/education/) · [公开 CV](https://www.zhongjiehuang.com/cv/) · [GitHub](https://github.com/zhongjiehuang1/pelagivex)

## 研究主线与区分

- **本科，谢菲尔德大学 Artificial Intelligence and Computer Science。** 用预训练 Swin Transformer 和 PyTorch 做人脸表情分类，接入 Java Web 摄像头原型。公开案例的原型按单张抓拍返回分类结果。它与 PelagiVex 共享模型到界面的工程经验。[本科项目](https://www.zhongjiehuang.com/projects/emotion-recognition/)
- **硕士，谢菲尔德大学 Artificial Intelligence。** 读了本机同步的脱敏论文 *DW-MSC-2 Automated extraction of quantitative data from histology images*。论文第 1.4 节以静态 H&E 图像为输入，比较 QuPath、Cellpose-DINO、Cyto R-CNN 和 CSGO，分别评估实例边界、匹配细胞的面积、口腔组织的形态统计和分级预测。摘要和第 6.1 节报告：在有标注的测试划分上，Cyto R-CNN 的边界和匹配面积结果领先；在口腔队列中，形态特征与冻结图像特征融合后没有明确改善分级预测。口腔数据缺少参考细胞轮廓，这限制了对解剖准确性的判断。这里依据的是论文的结果表述，未重新运行组织学实验。[硕士项目公开概览](https://www.zhongjiehuang.com/projects/histology-segmentation/)
- **PelagiVex 的新问题。** 输入是连续单目视频，研究对象是固定深度模型和跟踪器之后的在线复测策略。系统要回答两条跟踪轨迹的近远关系，并在证据失效时决定何时撤下方向、何时花一次推理确认。独立 RGB-D 真值支持按真实顺序翻转事件评估，重点是纠正延迟、显示错误的时长、方向覆盖率和推理成本。对照保持分割、跟踪和深度输入一致。这与硕士论文的静态分割方法比较在任务、实验干预、真值和主要指标上均有区分。[PelagiVex 案例](https://www.zhongjiehuang.com/projects/pelagivex/)

三个项目可以连成一条研究主线：把模型输出接进实际工作流，明确何时证据足以支持下游判断。官网的可靠 AI 研究方向提到了基线、失败分析和可复现评估。大学邮件里一份博士研究讨论幻灯的可读部分也把问题落在证据不足与选择性预测上。这里将这条方法论用于有时间约束和计算预算的视觉任务，并用可测量的物理顺序检验它。[研究方向](https://www.zhongjiehuang.com/research/) · [研究验证笔记](https://www.zhongjiehuang.com/insights/research-validation/)

## 实际读取范围

| 来源 | 本次读取情况 |
| --- | --- |
| 个人官网 | 读取了教育、研究方向、验证笔记、公开英文 CV（HTML 和 PDF）以及本科、硕士、PelagiVex 三个案例。公开硕士案例提供方法概览，实验结论依据本机论文。 |
| 本机同步文件 | 核对了署名论文原件的封面。读取了 75 页脱敏论文的摘要、研究问题、讨论与结论，重点是 PDF 第 3、12、54、63 页。原始论文和资料留在原位置。 |
| GitHub 和大学 Gmail 插件 | GitHub 确认仓库与官网及本地检出一致。读取了大学 Gmail 中的较早版 CV 附件和博士研究讨论幻灯的提取预览，也查到了与 COM6912 论文提交有关的邮件记录。早期 CV 仍列 MSc 结果待定，当前公开教育页和新版 CV 列已授予。 |
| ChatGPT 聊天、库与上传文件 | 通过桌面工具读到相关博士申请聊天及资料库整理记录。ChatGPT 项目索引显示 `PhD Applications`，所读聊天没有返回可读取的上传附件。Pages 插件的定向检索未找到相关页面。Chrome 打开的网页版 Library 需要登录，因此本次未能直接核对库内原文件。 |
| LinkedIn | 官网链接定位到确切档案。公共抓取失败，Chrome 打开后进入登录页面，LinkedIn 插件的同名检索未返回该档案。没有将其他同名搜索结果算作个人经历。[官网指向的 LinkedIn 档案](https://www.linkedin.com/in/zhongjie-huang-11a19b423/) |
