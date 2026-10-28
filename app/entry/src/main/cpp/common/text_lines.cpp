#include "text_lines.h"

void
SplitLines (const std::string &text, std::vector<std::string> &out)
{
  size_t pos = 0;
  while (pos < text.size ())
    {
      size_t nl = text.find ('\n', pos);
      if (nl == std::string::npos)
        nl = text.size ();
      out.push_back (text.substr (pos, nl - pos));
      pos = nl + 1;
    }
}
