#set text(
  font: "New Computer Modern",
  size: 10pt
)
#set page(
  paper: "a4",
  margin: (x: 1.8cm, y: 1.5cm),
)
#set par(
  justify: true,
  leading: 0.52em,
)
#set text(font: ("Times New Roman", "SimSun"))
#set par(first-line-indent: 2em)
#let fakepar=context{let b=par(box());b;v(-measure(b+b).height)}
#show math.equation.where(block: true): it=>it+fakepar // 公式后缩进
#show heading: it=>it+fakepar // 标题后缩进
#show figure: it=>it+fakepar // 图表后缩进
#show enum.item: it=>it+fakepar
#show list.item: it=>it+fakepar // 列表后缩进

#align(center, text(17pt)[
  *ZipPasswordCracker*
])
#align(center, text(13pt)[
  高性能压缩包口令破解工具
])

我们经常会遇到忘记口令的压缩包。也许是哪次下载资源后忘记及时解压，也许是资源上传者本身就没有提供解压口令。
总之，这样的压缩包总会让人难以处理：直接删除未免有些浪费，但又没有什么破解的办法。
因此，我开发了一个口令破解工具`ZipPasswordCracker`，能够高效地破解压缩包口令。

= 基本原理

该工具的基本原理非常简单：将所有可能的字符组合尝试一遍，就能找到最终合法的口令了。
然而，所有可能的字符组合实际上非常多。以纯数字组成的至多6位的口令为例，所有可能的字符组合数目为：
$10 + 10^2 + 10^3 + ... + 10^6$.
更一般地，可能的字符数量为$a$, 长度不高于$n$的所有可能组合为
$ sum_(i=1)^(i=n) a^i = (a^(n+1)-a)/(a-1) $
因此，我们需要一种效率足够高的手段来对所有可能的内容进行遍历。
注意到每次口令的尝试理论上是独立的，且口令尝试的顺序并不重要#footnote([这里指不影响程序正确性。尽早尝试到正确的口令能够让程序快速结束。但这在没有任何先验知识的情况下并不现实。])。
因此，我们可以使用并行化的方法来成倍地加快遍历过程。
在计算机上，程序的并行化手段包括多线程、多进程、GPU等手段。
其中，多线程程序编写快速，多进程程序能够在超算等多计算节点场景下使用，但需要解决进程间信息传递的问题。
GPU并行化受益于如今快速发展的GPU技术，计算速度最快，但涉及异构计算#footnote([使用不同类型的指令集和系统架构的计算单元组成系统的计算方式——wikipedia]).
在`ZipPasswordCracker`中，我们提供了两种并行化实现：多线程并行和GPU并行。
其中，多线程并行直接使用`pthread`库，因此能够直接在绝大多数计算机上编译和运行。
而GPU并行则使用`CUDA`编程，因此需要借助NVIDIA显卡以及`CUDA`运行时才能运行。

接下来，我将简要叙述`ZipPasswordCracker`的开发和优化过程。

= zip文件读取

实现`ZipPasswordCracker`的第一步就是实现zip文件的读取。
给定一个zip文件，程序需要判断其是否加密、加密类型。
若再给定一个字符串作为口令，程序还需要判断该口令是否正确。

查询#link("https://en.wikipedia.org/wiki/ZIP_(file_format)")[Wikipedia],
我们可以找到zip文件的文件头。
#figure(
  table(
    columns: 3,
    [偏移量], [长度], [内容], 
    [0], [4], [文件签名，0x04034b50],
    [4], [2], [解压所需的最低zip版本],
    [6], [2], [通用数据区],
    [8], [2], [压缩算法],
    [10], [2], [最后修改时间],
    [12], [2], [最后修改日期],
    [14], [4], [未压缩数据的CRC-32],
    [18], [4], [压缩后大小 (zip64下为0xffffffff)],
    [22], [4], [压缩前大小 (zip64下为0xffffffff)],
    [26], [2], [文件名长度 (n)],
    [28], [2], [额外数据区长度 (m)],
    [30], [n], [文件名],
    [30+n], [m], [额外数据区],
  )
)

根据这个文件头的定义，我们就能够构造如下数据结构
```C
struct local_file_header{
    uint32_t signature;
    uint16_t version_needed_to_extract;
    uint16_t general_purpose_bit_flag;
    uint16_t compression_method;
    uint16_t last_mod_file_time;
    uint16_t last_mod_file_date;
    uint32_t crc32;
    uint32_t compressed_size;
    uint32_t uncompressed_size;
    uint16_t file_name_length;
    uint16_t extra_field_length;
}__attribute__((packed));
```
只要将一个```C struct local_file_header*```结构体的指针指向文件的开头，就能自动在该结构体的成员中读取出对应的内容。
以下是一段例子
```C
// open the file
int fd = open(argv[1], O_RDONLY);
if (fd == -1) {
    perror("open");
    return 1;
}
// get file size
struct stat st;
if (fstat(fd, &st) == -1) {
    perror("fstat");
    return 1;
}
off_t size = st.st_size;
// map the file to memory
void *file = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
header = (struct local_file_header *)file;
```
读取了zip相关的信息后，我们还需要读取与加密相关的内容。
从`7-zip`创建zip文件的界面中，我们发现了一种常见的加密方式：AES-256.
通过查阅#link("https://www.winzip.com/en/support/aes-encryption/")[相关文档]，我们找到了AES加密后zip文件的特征：
+ 通用数据区最低位为1
+ 压缩算法为99(16进制下为0x63)

我们还找到了加密相关数据块的定义。

#figure(
  table(
    columns: 3,
    [偏移量], [长度], [内容], 
    [0], [2], [文件头，0x9901],
    [2], [2], [数据大小],
    [4], [2], [加密方法版本号],
    [6], [2], [加密方法ID, ASCII字符'AE'],
    [8], [1], [密钥长度, 0x01对应128bit, 0x02对应192bit, 0x03对应256bit]
  )
)
该数据块位于文件头的额外数据区。通过这些内容，我们就能够确定文件是否为AES加密的文件了。

验证口令是否正确的数据存放在每个文件的文件头内#footnote([zip文件可对每个文件单独设置口令。])。
但简单起见，我们直接检验口令对第一个文件是否正确。
这些数据块的定义为
#figure(
  table(
    columns: 2,
    [长度], [内容], 
    [可变], [盐], 
    [2], [口令验证码], 
    [可变], [文件数据], 
    [10], [授权码], 
  )
)

然而，该文档中并未提到如何验证口令是否正确。

= 口令验证

虽然文档中并未提及如何验证口令，但解压zip文件的开源代码却有很多。
通过学习#link("https://github.com/zip-rs/zip2/")[rust的zip库]，
我们能够学习到一种快速判断口令正确性的算法：
使用PBKDF2-HMAC-SHA1算法将口令和盐迭代1000次，得到长度为`salt_length` $*4+2$的衍生口令。
随后，比较衍生口令的最后两位与口令验证码，若不同则口令错误。

需要注意的是，如此比较显然不能成为口令正确的充分条件。
假设衍生口令的各字节内容均随机，则衍生口令与口令验证码重合的概率为$1/(2^8)^2 = 1/65536$.
相比广阔的口令空间，这个概率显然算不上小。
事实上，如果设定口令范围为数字组成的字符串，且口令最长5个字符，则通常能够找到2-3个符合的口令。
用这种方法将可能的口令空间缩减到$1/65536$, 之后再使用更精细的算法逐一验证似乎是一个不错的想法。

因此，我们首先实现这个口令验证算法。
在#link("https://github.com/zip-rs/zip2/")[zip库]中，作者直接使用了内置的PBKDF2-HMAC-SHA1函数。
但在C语言中，类似的轮子并不存在。
因此，我们依次实现了`SHA1`、`HMAC-SHA1`和`PBKDF2-HMAC-SHA1`函数，随后完成了口令验证函数`is_valid_key()`
经过验证，我们的口令验证函数能够正确识别口令。
加之一个简单的口令遍历算法，我们就得到了一个单线程版本的密码破解程序。
当然，这个版本的密码破解程序运行速度十分缓慢。
在Inter 12400F CPU上(启用超线程)，WSL Ubuntu操作系统中，为了破解一个长度不超过4位，完全由数字构成的口令，该程序需要运行55秒。
但它能够找到正确的口令——这是一个不错的开始。
无数开发经验告诉我们，要首先编写正确的代码，然后再编写高效的代码。
既然我们已经实现了正确性，在此基础上，我们就能够开始通过多线程和GPU来提高程序的效率了。

= 多线程实现

由于现代CPU的核心数量有了大幅的增长，使用多线程程序能够更高效地利用CPU资源。
在这个程序中，多线程的实现十分简单。
这是因为线程之间仅需要共享合法字符表以及盐、口令验证码。
而且各线程均不需要写入这些内容。
因此，在这个程序中，并不存在程序之间潜在的数据竞争，因而无需使用锁、信号量等复杂的机制。
我们从主线程出发，将各线程所需的信息(或指向信息的指针)封装在一个结构体中，
并使用`pthraed`库创建线程。
这样，我们就能借助多线程轻松地提高程序地性能了。
在Inter 12400F CPU上(启用超线程)，WSL Ubuntu操作系统中，为了破解一个长度不超过4位，完全由数字构成的口令，
使用10线程，该程序仅需10秒就能完成遍历——速度提升到了原来的5倍！#footnote([该CPU的12个线程存在于6个物理内核中。由于多线程的特性，在计算密集型任务(如本程序)中，超线程的性能提升远远不如线程数的提升。])
