// macOS shared credentials: owner-only files, readable by the app helper and
// injected Steam process. Never logs tokens and never falls back to public files.
#include "cloud_provider_base.h"
#include <filesystem>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <vector>
class MacTokenStore final : public ITokenStore {
public:
    std::string Read(const std::string& path) override {
        int fd=open(path.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return {};
        struct stat st{};std::string data;
        if(fstat(fd,&st)==0&&S_ISREG(st.st_mode)&&st.st_uid==getuid()&&
           (st.st_mode&0077)==0&&st.st_size>0&&st.st_size<=1024*1024) {
            data.resize(st.st_size);size_t done=0;
            while(done<data.size()){ssize_t n=read(fd,data.data()+done,data.size()-done);if(n<0&&errno==EINTR)continue;if(n<=0){data.clear();break;}done+=n;}
        }
        close(fd);return data;
    }
    bool Write(const std::string& path,const std::string& json) override {
        std::error_code ec;auto parent=std::filesystem::path(path).parent_path();
        std::filesystem::create_directories(parent,ec);if(ec)return false;
        std::string pattern=path+".XXXXXX";std::vector<char> temp(pattern.begin(),pattern.end());temp.push_back(0);
        int fd=mkstemp(temp.data());if(fd<0)return false;fchmod(fd,0600);
        bool ok=true;size_t done=0;
        while(done<json.size()){ssize_t n=write(fd,json.data()+done,json.size()-done);if(n<0&&errno==EINTR)continue;if(n<=0){ok=false;break;}done+=n;}
        if(ok)ok=fsync(fd)==0;close(fd);
        if(ok)ok=rename(temp.data(),path.c_str())==0;
        if(!ok)unlink(temp.data());return ok;
    }
    bool IsEncryptionAvailable() const override { return false; }
};
std::unique_ptr<ITokenStore> CreateTokenStore(){return std::make_unique<MacTokenStore>();}
